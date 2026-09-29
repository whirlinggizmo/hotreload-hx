"""drive.py: runs a hot program, edits its sources while it runs, and waits for its output.
Imported by the scenario scripts."""
import os, re, shutil, subprocess, sys, time

class Program:
    def __init__(self, cwd, argv, log, env=None):
        self.cwd, self.log = cwd, log
        self.out = open(log, "w")
        self.p = subprocess.Popen(argv, cwd=cwd, stdout=self.out, stderr=subprocess.STDOUT, env=env)
        self.pos = 0
    def lines(self):
        with open(self.log) as f:
            f.seek(self.pos)
            data = f.read()
        end = data.rfind("\n")
        if end < 0:
            return []
        self.pos += len(data[:end + 1].encode())
        return data[:end].split("\n")
    def wait(self, pattern, timeout=60, show=True):
        """the first line matching, showing what else it said"""
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        while time.time() < deadline:
            for l in self.lines():
                if show and not l.startswith("main: held") :
                    print("    | " + l)
                if rx.search(l):
                    return l
            time.sleep(0.02)
        print("    !! timed out waiting for " + pattern)
        return None
    def stop(self):
        self.p.terminate()
        try: self.p.wait(5)
        except subprocess.TimeoutExpired: self.p.kill()
        self.out.close()

def save(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f: f.write(text)
    os.replace(tmp, path)

def edit(path, old, new):
    text = open(path).read()
    assert old in text, f"{path} has no {old!r}"
    save(path, text.replace(old, new))

def install(src_dir, dst_dir):
    for root, _, files in os.walk(src_dir):
        for name in files:
            s = os.path.join(root, name)
            d = os.path.join(dst_dir, os.path.relpath(s, src_dir))
            os.makedirs(os.path.dirname(d), exist_ok=True)
            save(d, open(s).read())
