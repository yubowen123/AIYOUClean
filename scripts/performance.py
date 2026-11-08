#!/usr/bin/env python3
"""Bounded synthetic scanner benchmark. Never scans or removes pre-existing user files."""
import argparse,json,pathlib,resource,subprocess,time,uuid,shutil
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--count',type=int,default=10000);p.add_argument('--kind',default='duplicates');p.add_argument('--label',required=True);p.add_argument('--file-bytes',type=int,default=0);p.add_argument('--results-limit',type=int);p.add_argument('--flat',action='store_true');p.add_argument('--assert-rss-mb',type=int);p.add_argument('--max-rss-mb',type=int,default=512);a=p.parse_args()
project=pathlib.Path(__file__).resolve().parent.parent
fixture=project/'.perf-fixtures'/str(uuid.uuid4());fixture.mkdir(parents=True)
out=project/'analysis/performance';out.mkdir(parents=True,exist_ok=True)
resultpath=out/(a.label+'-scan.json');logpath=out/(a.label+'-stderr.txt')
try:
    for i in range(a.count):
        folder=fixture if a.flat else fixture/f'{i//1000:03d}';folder.mkdir(exist_ok=True)
        if a.file_bytes:
            with (folder/f'{i:08d}.txt').open('wb') as f:f.truncate(a.file_bytes)
        else:(folder/f'{i:08d}.txt').write_bytes(f'AIYOUClean generated unique record {i:016x}\n'.encode())
    command=[str(pathlib.Path(a.binary).resolve()),'scan',a.kind,'--root',str(fixture),'--max-files',str(a.count*2),'--max-seconds','120','--output',str(resultpath)]
    if a.results_limit is not None:command.extend(['--max-results',str(a.results_limit)])
    before=resource.getrusage(resource.RUSAGE_CHILDREN);start=time.monotonic();sampled=0;stopped=False
    with logpath.open('wb') as log:
        child=subprocess.Popen(command,stdout=log,stderr=log)
        while child.poll() is None:
            sample=subprocess.run(['/bin/ps','-o','rss=','-p',str(child.pid)],capture_output=True,text=True)
            try:sampled=max(sampled,int(sample.stdout.strip())*1024)
            except ValueError:pass
            if sampled>a.max_rss_mb*1024*1024 or time.monotonic()-start>150:
                stopped=True;child.terminate()
                try:child.wait(timeout=2)
                except subprocess.TimeoutExpired:child.kill();child.wait()
                break
            time.sleep(.08)
        code=child.wait()
    after=resource.getrusage(resource.RUSAGE_CHILDREN)
    result={'label':a.label,'files':a.count,'kind':a.kind,'fileBytesEach':a.file_bytes,'flat':a.flat,'exitCode':code,'watchdogStopped':stopped,'seconds':round(time.monotonic()-start,3),'peakRSSBytes':max(sampled,int(after.ru_maxrss)),'userSeconds':round(after.ru_utime-before.ru_utime,3),'systemSeconds':round(after.ru_stime-before.ru_stime,3),'rssBudgetMB':a.max_rss_mb}
    if resultpath.exists():
        report=json.loads(resultpath.read_text());result.update(items=len(report['items']),visited=report['visitedFiles'],truncated=report['truncated'])
    (out/(a.label+'.json')).write_text(json.dumps(result,indent=2));print(json.dumps(result))
    if a.assert_rss_mb is not None and (stopped or code not in (0,3) or result['peakRSSBytes']>a.assert_rss_mb*1024*1024):raise SystemExit(1)
finally:
    shutil.rmtree(fixture)
    try:fixture.parent.rmdir()
    except OSError:pass
