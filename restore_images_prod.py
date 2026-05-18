"""
Server-side image restore: converts flat-format images in /opt/wikibase/images/
to MediaWiki hashed directory structure, then docker cp into the container.
"""
import os, hashlib, shutil, tempfile, subprocess

images_src = "/opt/wikibase/images"
container = "wikibase"
container_dst = "/var/www/html/images"

def mw_hash(mw_name):
    dbkey = mw_name.replace(" ", "_")
    if dbkey:
        dbkey = dbkey[0].upper() + dbkey[1:]
    h = hashlib.md5(dbkey.encode("utf-8")).hexdigest()
    return h[0], h[:2]

staging = tempfile.mkdtemp(prefix="mw_restore_")
print(f"Staging: {staging}", flush=True)

count = 0
for entry in sorted(os.listdir(images_src)):
    src = os.path.join(images_src, entry)
    if not os.path.isfile(src):
        continue
    # flat format: "{md5hash} {filename}" -> MW name is entry with space->underscore
    mw_name = entry.replace(" ", "_")
    if mw_name:
        mw_name = mw_name[0].upper() + mw_name[1:]
    d1, d12 = mw_hash(mw_name)
    dest_dir = os.path.join(staging, d1, d12)
    os.makedirs(dest_dir, exist_ok=True)
    shutil.copy2(src, os.path.join(dest_dir, mw_name))
    count += 1

print(f"Staged {count} files", flush=True)

r = subprocess.run(
    ["docker", "cp", staging + "/.", f"{container}:{container_dst}"],
    capture_output=True, text=True
)
if r.returncode != 0:
    print(f"ERROR: {r.stderr}", flush=True)
else:
    print("docker cp done", flush=True)

r2 = subprocess.run(
    ["docker", "exec", container, "chown", "-R", "www-data:www-data", container_dst],
    capture_output=True, text=True
)
if r2.returncode != 0:
    print(f"chown warning: {r2.stderr}", flush=True)

shutil.rmtree(staging, ignore_errors=True)
print("Staging cleaned up.", flush=True)

# Verify
r3 = subprocess.run(
    ["docker", "exec", container, "find", container_dst, "-type", "f",
     "!", "-name", ".htaccess", "!", "-name", "README"],
    capture_output=True, text=True
)
file_count = len(r3.stdout.strip().splitlines())
print(f"Files now in container images dir: {file_count}", flush=True)
