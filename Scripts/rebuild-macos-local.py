#!/usr/bin/env python3
"""Rebuild a local test app with CLT, reusing matching compiled nibs/assets.
This is a development comparison tool, not a substitute for an Xcode release
build. Dependencies must already be installed by Scripts/setup.sh. It neither
installs dependencies nor starts GitHub Actions.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT/'.build/local-compare'

def checked(args, **kwargs):
    return subprocess.run(args, check=True, cwd=ROOT, **kwargs)

def capture(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()

def sources_at(ref):
    if not ref:
        return ROOT
    sha = capture(['git','rev-parse',ref+'^{commit}'])
    destination = CACHE/'sources'/sha
    if not destination.exists():
        destination.mkdir(parents=True)
        archive = CACHE/(sha+'.tar')
        with archive.open('wb') as stream:
            checked(['git','archive',sha],stdout=stream)
        checked(['tar','-xf',str(archive),'-C',str(destination)])
        archive.unlink()
    return destination

def verify_resources(source, ref, app):
    # Changed nibs/assets/build configuration require Xcode. Never silently reuse
    # compiled interfaces from a different source layout.
    paths = capture(['git','ls-tree','-r','--name-only',ref]).splitlines()
    compiled_inputs = {p for p in paths if p.startswith('MacDown/') and
                       (p.endswith('.xib') or '.xcassets/' in p)}
    current_inputs = {p.relative_to(source).as_posix() for p in (source/'MacDown').rglob('*')
                      if p.is_file() and p.name != '.DS_Store' and
                      (p.suffix == '.xib' or '.xcassets/' in p.relative_to(source).as_posix())}
    if compiled_inputs != current_inputs:
        raise SystemExit('Cannot reuse compiled resources: added or removed interface/asset inputs')
    for relative in paths:
        if (relative.endswith('.xib') or '.xcassets/' in relative or
            relative == 'MacDown.xcodeproj/project.pbxproj' or
            relative in ('MacDown/MacDown-Info.plist','Podfile','Podfile.lock')):
            old = subprocess.check_output(['git','show',f'{ref}:{relative}'],cwd=ROOT)
            path = source/relative
            if not path.exists() or path.read_bytes()!=old:
                raise SystemExit(f'Cannot reuse compiled resources: {relative} differs from {ref}')
    with (app/'Contents/Info.plist').open('rb') as stream: info=plistlib.load(stream)
    for key,file in [('CFBundleShortVersionString','Tools/version.txt'),('CFBundleVersion','Tools/build-number.txt')]:
        if str(info[key])!=(source/file).read_text().strip():
            raise SystemExit(f'Resource app {key} does not match {file}')
    if (source/'Podfile.lock').read_bytes()!=(ROOT/'Podfile.lock').read_bytes():
        raise SystemExit('Source dependencies do not match installed dependency lockfile')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources-app',required=True,type=Path)
    parser.add_argument('--resources-ref',required=True,help='Git revision that produced the compiled nibs/assets')
    parser.add_argument('--source-ref',help='Build this Git revision; default is the working tree')
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--universal',action='store_true',help='Build arm64 and x86_64; default is host architecture only')
    args=parser.parse_args();CACHE.mkdir(parents=True,exist_ok=True)
    source=sources_at(args.source_ref);app=args.resources_app.resolve();output=args.output.resolve()
    if not (app/'Contents/MacOS/MacDown').is_file(): raise SystemExit('Missing resource app')
    if output==app or output==source or not any(p in output.parents for p in [ROOT/'.build', ROOT/'Artifacts']) or output.suffix!='.app':
        raise SystemExit('Output must be a separate .app under .build or Artifacts')
    verify_resources(source,args.resources_ref,app)
    if not (ROOT/'Pods/Pods.xcodeproj').exists(): raise SystemExit('Install dependencies first: Scripts/setup.sh')
    checked(['make','-C',str(source/'Dependency/peg-markdown-highlight')],stdout=subprocess.DEVNULL)
    ruby='''require 'json'; require 'xcodeproj'
rows=[]
[[ARGV[0],true],[ARGV[1],false]].each do |path,app|
 project=Xcodeproj::Project.open(path)
 project.targets.each do |target|
  next if app ? target.name != 'MacDown' : %w[Pods-MacDown Pods-MacDownTests Pods-macdown-cmd GBCli Sparkle].include?(target.name)
  next unless target.respond_to?(:source_build_phase)
  files=target.source_build_phase.files.filter_map do |file|
   next unless file.file_ref
   {path:file.file_ref.real_path.to_s,flags:file.settings && file.settings['COMPILER_FLAGS']}
  end
  rows << {name:target.name,sources:files}
 end
end
puts JSON.generate(rows)
'''
    manifest=json.loads(capture(['ruby','-rbundler/setup','-rxcodeproj','-e',ruby,str(source/'MacDown.xcodeproj'),str(ROOT/'Pods/Pods.xcodeproj')]))
    generated=CACHE/'generated';generated.mkdir(exist_ok=True)
    grammars=list((ROOT/'Pods/handlebars-objc').rglob('*.ym'))
    lexers=list((ROOT/'Pods/handlebars-objc').rglob('*.lm'))
    if len(grammars)!=1 or len(lexers)!=1:raise SystemExit('Unexpected handlebars parser sources')
    checked(['bison','-d','-o',str(generated/'y.tab.c'),str(grammars[0])],stdout=subprocess.DEVNULL)
    (generated/'y.tab.c').replace(generated/'parser.m')
    checked(['flex','-o',str(generated/'lex.yy.m'),str(lexers[0])])
    sdk=capture(['xcrun','--show-sdk-path'])
    include_roots=[source/'MacDown/Code',ROOT/'Pods/Headers',ROOT/'Pods/handlebars-objc']
    includes=['-I'+str(p) for directory in include_roots for p in [directory,*sorted(p for p in directory.rglob('*') if p.is_dir())]]
    includes+=['-I'+str(source/p) for p in ['Dependency/peg-markdown-highlight','Dependency/YAML-framework','Dependency/version']]
    includes+=['-I'+str(ROOT/'Pods/LibYAML'),'-I'+str(generated)]
    common=['xcrun','clang','-c','-Os','-fno-modules','-fvisibility=default','-DNS_BLOCK_ASSERTIONS=1','-DCOCOAPODS=1',
            '-isysroot',sdk,'-mmacosx-version-min=13.0','-F'+str(ROOT/'Pods/Sparkle'),*includes]
    # Header and toolchain changes invalidate cached objects, not just .m edits.
    header_hash=hashlib.sha256(capture(['xcrun','clang','--version']).encode())
    for directory in [source/'MacDown/Code',ROOT/'Pods',source/'Dependency',generated]:
        for path in sorted(directory.rglob('*.h')):header_hash.update(path.read_bytes())
    context=header_hash.digest()
    sources=[]
    for target in manifest:
        for entry in target['sources']:
            path=Path(entry['path']);extra=shlex.split(entry['flags'] or '')
            if path.suffix in ('.ym','.lm'):
                path=generated/('parser.m' if path.suffix=='.ym' else 'lex.yy.m');extra=['-fno-objc-arc']
            if path.suffix not in ('.m','.c'):continue
            flags=[]
            if path.suffix=='.m':flags+=['-fobjc-arc','-include',str(source/'MacDown/Code/MacDown-Prefix.pch')]
            if target['name']=='LibYAML':flags+=['-DHAVE_CONFIG_H']
            sources.append((path,flags+extra))
    objects=CACHE/'objects';objects.mkdir(exist_ok=True)
    archs=['arm64','x86_64'] if args.universal else [platform.machine()]
    def compile_one(job):
        arch,path,flags=job
        digest=hashlib.sha256(context+str((common,arch,path,flags)).encode()+path.read_bytes()).hexdigest()
        obj=objects/(digest+'.o');log=objects/(digest+'.log')
        if not obj.exists():
            with log.open('w') as stream:
                result=subprocess.run([*common,'-arch',arch,*flags,str(path),'-o',str(obj)],stdout=stream,stderr=stream)
            if result.returncode:raise RuntimeError(str(path)+'\n'+log.read_text()[-5000:])
        return arch,obj
    with ThreadPoolExecutor(max_workers=3) as pool:
        compiled=list(pool.map(compile_one,[(arch,path,flags) for arch in archs for path,flags in sources]))
    binaries=[]
    for arch in archs:
        binary=CACHE/('MacDown-'+arch)
        command=['xcrun','clang','-arch',arch,'-isysroot',sdk,'-mmacosx-version-min=13.0','-F'+str(ROOT/'Pods/Sparkle'),
                 *[str(obj) for a,obj in compiled if a==arch],'-o',str(binary),'-Wl,-rpath,@executable_path/../Frameworks']
        for framework in ['Cocoa','WebKit','JavaScriptCore','QuartzCore','Sparkle']:command+=['-framework',framework]
        checked(command);binaries.append(binary)
    if output.exists():shutil.rmtree(output)
    output.parent.mkdir(parents=True,exist_ok=True)
    checked(['ditto',str(app),str(output)])
    executable=output/'Contents/MacOS/MacDown'
    if len(binaries)>1:checked(['lipo','-create',*[str(p) for p in binaries],'-output',str(executable)])
    else:shutil.copy2(binaries[0],executable)
    # These resources are copied folders in Xcode, and need no Interface Builder.
    checked(['ditto',str(source/'MacDown/Resources'),str(output/'Contents/Resources')])
    info_path=output/'Contents/Info.plist'
    with info_path.open('rb') as stream:info=plistlib.load(stream)
    info['MPLocalComparisonBuild']=True
    info['MPCompiledResourcesRevision']=capture(['git','rev-parse',args.resources_ref])
    info['MPSourceRevision']=capture(['git','rev-parse',args.source_ref or 'HEAD'])
    info['MPSourceWorkingTree']=not bool(args.source_ref)
    with info_path.open('wb') as stream:plistlib.dump(info,stream)
    checked(['codesign','--force','--sign','-',str(output)])
    checked(['codesign','--verify','--deep','--strict',str(output)])
    checked(['lipo',str(executable),'-verify_arch',*archs])
    print('Local comparison app:',output)

if __name__=='__main__':main()
