#!/usr/bin/env python3
"""Produce Phase-1 evidence only after checking the signed APT publication.

This intentionally stops at waiting-source: SOURCE identifies the PVE commit,
but it cannot stand in for the missing exact Ubuntu source snapshot/patches.
"""
import argparse, gzip, hashlib, json, os, re, subprocess, sys, tempfile
from pathlib import Path

HEX64=re.compile(r"^[0-9a-f]{64}$"); COMMIT=re.compile(r"^[0-9a-f]{40}$")
def digest(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
def fail(s): print(s,file=sys.stderr); raise SystemExit(3)
def fields(data):
 out=[]
 for stanza in data.decode().strip().split('\n\n'):
  d={}; key=None
  for line in stanza.splitlines():
   if line.startswith((' ','\t')) and key: d[key]+='\n'+line[1:]
   elif ': ' in line: key,val=line.split(': ',1); d[key]=val
  if d: out.append(d)
 return out
def release_sha(inrelease, path):
 seen=False
 for line in Path(inrelease).read_text(encoding='utf-8',errors='strict').splitlines():
  if line=='SHA256:': seen=True; continue
  if seen and re.match(r'^\S',line): break
  if seen:
   m=re.match(r'^ ([0-9a-f]{64})\s+\d+\s+(.+)$',line)
   if m and m.group(2)==path: return m.group(1)
 fail('signed InRelease has no SHA256 for requested Packages path')
def dpkg_field(deb, field, fallback):
 cmd=['dpkg-deb','-f',str(deb),field] if not fallback else ['podman','run','--rm','--network=none','--userns=keep-id','--entrypoint','dpkg-deb','-v',f'{deb.parent}:/evidence:ro,Z','dockurr/proxmox:9.2.10','-f',f'/evidence/{deb.name}',field]
 return subprocess.check_output(cmd,text=True).strip()
def member(deb, name, fallback):
 if not fallback:
  p=subprocess.Popen(['dpkg-deb','--fsys-tarfile',str(deb)],stdout=subprocess.PIPE)
 else:
  p=subprocess.Popen(['podman','run','--rm','--network=none','--userns=keep-id','--entrypoint','dpkg-deb','-v',f'{deb.parent}:/evidence:ro,Z','dockurr/proxmox:9.2.10','--fsys-tarfile',f'/evidence/{deb.name}'],stdout=subprocess.PIPE)
 t=subprocess.run(['tar','-xOf','-', './'+name],stdin=p.stdout,stdout=subprocess.PIPE)
 if p.wait()!=0 or t.returncode: fail(f'deb lacks {name} or extraction failed')
 return t.stdout
def main():
 p=argparse.ArgumentParser()
 for n in ('kver','arch','kernel_package','headers_package','packages_path','keyring_provenance'): p.add_argument('--'+n.replace('_','-'),required=True)
 for n in ('keyring','inrelease','packages','kernel_deb','headers_deb','output'): p.add_argument('--'+n.replace('_','-'),type=Path,required=True)
 p.add_argument('--pve-repo',type=Path); p.add_argument('--ubuntu-repo',type=Path)
 a=p.parse_args(); fallback=not bool(__import__('shutil').which('dpkg-deb'))
 for f in (a.keyring,a.inrelease,a.packages,a.kernel_deb,a.headers_deb):
  if not f.is_file(): fail(f'missing evidence input: {f}')
 try: subprocess.run(['gpgv','--keyring',str(a.keyring),str(a.inrelease)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 except subprocess.CalledProcessError: fail('InRelease signature verification failed')
 expected=release_sha(a.inrelease,a.packages_path)
 if digest(a.packages)!=expected: fail('Packages.gz digest does not match signed InRelease')
 try: entries=fields(gzip.open(a.packages,'rb').read())
 except Exception: fail('invalid Packages.gz')
 def exact(identity, deb):
  if '=' not in identity: fail('package identity must be NAME=VERSION')
  name,version=identity.split('=',1)
  hits=[x for x in entries if x.get('Package')==name and x.get('Version')==version and x.get('Architecture')==a.arch]
  if len(hits)!=1: fail(f'no unique package index entry for {identity}')
  x=hits[0]
  if not HEX64.match(x.get('SHA256','')) or digest(deb)!=x['SHA256']: fail(f'exact deb digest mismatch: {identity}')
  for k,v in [('Package',name),('Version',version),('Architecture',a.arch)]:
   if dpkg_field(deb,k,fallback)!=v: fail(f'deb control mismatch: {identity} {k}')
  return x
 kernel=exact(a.kernel_package,a.kernel_deb); headers=exact(a.headers_package,a.headers_deb)
 # These binary packages must be from the same explicitly-versioned source build.
 def source_id(x):
  raw=x.get('Source',''); m=re.fullmatch(r'([^ ]+)(?: \(([^)]+)\))?',raw)
  return (m.group(1),m.group(2) or x['Version']) if m else fail('malformed Source field')
 if source_id(kernel)!=source_id(headers): fail('kernel and headers are not one exact source build')
 kname=a.kernel_package.split('=',1)[0]; hname=a.headers_package.split('=',1)[0]
 source=member(a.kernel_deb,f'usr/share/doc/{kname}/SOURCE',fallback)
 m=re.search(rb'^git checkout ([0-9a-f]{40})$',source,re.M)
 if not m: fail('SOURCE has no exact PVE commit')
 config=member(a.headers_deb,f'usr/src/linux-headers-{a.kver}/.config',fallback)
 symvers=member(a.headers_deb,f'usr/src/linux-headers-{a.kver}/Module.symvers',fallback)
 pve=m.group(1).decode(); source={'pve_commit':pve,'ubuntu_kernel_commit':None,'patches':None,'source_snapshot_sha256':None}; status='waiting-source'; reason='exact Ubuntu source snapshot and PVE patch evidence are unavailable'
 if a.pve_repo and a.ubuntu_repo:
  def git(repo,*args): return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
  try:
   link=git(a.pve_repo,'ls-tree',pve,'submodules/ubuntu-kernel').split()[2]
   if not COMMIT.match(link): fail('invalid PVE ubuntu-kernel gitlink')
   # `cat-file` and archive make the recovered object usable without lazy fetch.
   subprocess.run(['git','-C',str(a.ubuntu_repo),'cat-file','-e',link+'^{commit}'],check=True)
   subprocess.run(['git','-C',str(a.ubuntu_repo),'archive','--format=tar',link],check=True,stdout=subprocess.DEVNULL)
   names=git(a.pve_repo,'ls-tree','-r','--name-only',pve,'patches/kernel').splitlines()
   patches=[{'path':n,'sha256':hashlib.sha256(subprocess.check_output(['git','-C',str(a.pve_repo),'show',f'{pve}:{n}'])).hexdigest()} for n in names if n.endswith('.patch')]
   source.update({'ubuntu_kernel_commit':link,'patches':patches,'source_snapshot_sha256':None})
   status='resolved'; reason='Phase 1 identity resolved; no build, ABI, or boot-support claim'
  except (subprocess.CalledProcessError,IndexError): fail('supplied exact source repositories do not prove the required commits')
 result={'schema_version':1,'resolution_status':status,'trust':{'mode':'authenticated-apt-publication','keyring_sha256':digest(a.keyring),'keyring_provenance':a.keyring_provenance,'inrelease_sha256':digest(a.inrelease),'packages_path':a.packages_path,'packages_sha256':digest(a.packages),'extractor':'podman-dpkg-deb' if fallback else 'native-dpkg-deb'},'target':{'kver':a.kver,'architecture':a.arch,'kernel_package':{'name':kname,'version':kernel['Version'],'sha256':kernel['SHA256']}},'headers':{'status':'ready','package':{'name':hname,'version':headers['Version'],'sha256':headers['SHA256']}},'source':source,'integrity':{'kernel_package_sha256':kernel['SHA256'],'headers_package_sha256':headers['SHA256'],'headers_config_sha256':hashlib.sha256(config).hexdigest(),'module_symvers_sha256':hashlib.sha256(symvers).hexdigest()},'build':{'toolchain':None,'vermagic':None,'artifact_sha256':None},'reason':reason}
 a.output.parent.mkdir(parents=True,exist_ok=True)
 fd,tmp=tempfile.mkstemp(dir=a.output.parent,prefix='.target.'); os.close(fd)
 try:
  Path(tmp).write_text(json.dumps(result,sort_keys=True)+'\n'); os.replace(tmp,a.output)
 finally:
  if os.path.exists(tmp): os.unlink(tmp)
if __name__=='__main__': main()
