"""Bounded, read-only process/host memory attribution. Never changes OS settings."""
import json
import time

from .safety import local_path, available_memory_check, GIB


class MemoryTimeline:
    def __init__(self,path,*,floor_bytes=2*GIB):
        self.path=local_path(path)
        self.path.parent.mkdir(parents=True,exist_ok=True)
        self.stream=self.path.open("x",encoding="utf-8")
        self.started=time.perf_counter()
        self.floor_bytes=floor_bytes
        self.peak_rss=0

    def observe(self,pid,stage):
        import psutil
        records=[]
        try:
            parent=psutil.Process(pid)
            for process in [parent]+parent.children(recursive=True):
                try:
                    memory=process.memory_info()
                    records.append({"pid":process.pid,"name":process.name(),"rss_bytes":memory.rss,
                        "private_bytes":getattr(memory,"private",None),"vms_bytes":memory.vms})
                except psutil.NoSuchProcess:
                    pass
        except psutil.NoSuchProcess:
            pass
        host=psutil.virtual_memory()
        rss=sum(row["rss_bytes"] for row in records)
        self.peak_rss=max(self.peak_rss,rss)
        row={"epoch_seconds":time.time(),"elapsed_seconds":time.perf_counter()-self.started,
            "stage":stage,"processes":records,"rss_bytes":rss,"peak_rss_bytes":self.peak_rss,
            "host_available_bytes":host.available,"host_total_bytes":host.total}
        self.stream.write(json.dumps(row,allow_nan=False)+"\n");self.stream.flush()
        available_memory_check(host.available,host.total,floor_bytes=self.floor_bytes)
        return row

    def close(self):
        self.stream.close()
