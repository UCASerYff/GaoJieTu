#!/usr/bin/env python3
"""Artifact/provenance unit tests. Synthetic files only; never launches an app."""
import importlib.util,json,os,pathlib,plistlib,subprocess,tempfile,unittest,zipfile
spec=importlib.util.spec_from_file_location('verify_release',pathlib.Path(__file__).with_name('verify_release.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ReleaseTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='GaoJieTu-release-unit-');self.root=pathlib.Path(self.tmp.name);self.previous=pathlib.Path.cwd();os.chdir(self.root)
  self.info={'CFBundleIdentifier':'com.gaoseries.GaoJieTu','CFBundleExecutable':'GaoJieTu','CFBundleShortVersionString':'1.01','CFBundleVersion':'2'}
  caps=json.dumps({'appVersion':'1.01','actions':[]}).encode();self.source={'Resources/Info.plist':plistlib.dumps(self.info),'Resources/GaoCapabilities.json':caps,'Sources/fixture.swift':b'// synthetic source, not an executable\n','Assets/AppIcon.icns':b'SYNTHETIC ICON'}
  for name,data in self.source.items():p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
  subprocess.run(['git','init','-q'],check=True);subprocess.run(['git','add','.'],check=True)
  subprocess.run(['git','-c','user.name=Synthetic','-c','user.email=test@example.invalid','commit','-qm','synthetic source'],check=True)
  self.commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
  self.app={'Contents/Info.plist':self.source['Resources/Info.plist'],'Contents/Resources/GaoCapabilities.json':caps,'Contents/Resources/BuildInfo.json':json.dumps({'sourceCommit':self.commit,'sourceDirty':False,'version':'1.01','build':'2'}).encode(),'Contents/MacOS/GaoJieTu':b'NON-EXECUTABLE SYNTHETIC FIXTURE','Contents/Resources/AppIcon.icns':self.source['Assets/AppIcon.icns'],'Contents/_CodeSignature/CodeResources':b'SYNTHETIC SIGNATURE'}
  self.appzip=self.root/'app.zip';self.sourcezip=self.root/'source.zip';self.sums=self.root/'SHA256SUMS.txt';self.write()
 def tearDown(self):os.chdir(self.previous);self.tmp.cleanup()
 def write(self):
  for path,files in [(self.appzip,{'搞截图.app/'+k:v for k,v in self.app.items()}),(self.sourcezip,self.source)]:
   with zipfile.ZipFile(path,'w') as z:
    for name,data in files.items():z.writestr(name,data)
  self.sums.write_text(''.join(m.sha(p.read_bytes())+'  '+p.name+'\n' for p in [self.appzip,self.sourcezip]))
 def verify(self,installed=None):return m.verify(self.appzip,self.sourcezip,self.sums,self.commit,installed)
 def test_matching_artifacts_and_installed_bytes(self):
  installed=self.root/'installed.app'
  for name,data in self.app.items():p=installed/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
  r=self.verify(installed);self.assertTrue(r['installedVerified']);self.assertEqual(r['applicationFileCount'],6)
 def test_source_missing_file(self):
  del self.source['Sources/fixture.swift'];self.write()
  with self.assertRaisesRegex(RuntimeError,'complete selected commit'):self.verify()
 def test_source_changed_bytes(self):
  self.source['Sources/fixture.swift']=b'changed';self.write()
  with self.assertRaisesRegex(RuntimeError,'source bytes'):self.verify()
 def test_build_wrong_commit_or_dirty(self):
  for change in [{'sourceCommit':'0'*40},{'sourceDirty':True}]:
   v=json.loads(self.app['Contents/Resources/BuildInfo.json']);v.update(change);self.app['Contents/Resources/BuildInfo.json']=json.dumps(v).encode();self.write()
   with self.assertRaisesRegex(RuntimeError,'clean commit'):self.verify()
 def test_build_version_differs(self):
  v=dict(self.info);v['CFBundleVersion']='3';self.app['Contents/Info.plist']=plistlib.dumps(v);self.write()
  with self.assertRaisesRegex(RuntimeError,'version or identity'):self.verify()
 def test_checksum_tamper(self):
  self.sums.write_text('0'*64+'  app.zip\n'+'0'*64+'  source.zip\n')
  with self.assertRaisesRegex(RuntimeError,'checksum mismatch'):self.verify()
 def test_unexpected_private_file_inside_app(self):
  self.app['Contents/Resources/private-screen.png']=b'PRIVATE FIXTURE';self.write()
  with self.assertRaisesRegex(RuntimeError,'unexpected or missing files'):self.verify()
 def test_resource_fork_metadata_rejected(self):
  with zipfile.ZipFile(self.appzip,'a') as z:z.writestr('__MACOSX/._private','PRIVATE FIXTURE')
  with self.assertRaisesRegex(RuntimeError,'unrelated files'):self.verify()
 def test_icon_differs_from_source(self):
  self.app['Contents/Resources/AppIcon.icns']=b'CHANGED';self.write()
  with self.assertRaisesRegex(RuntimeError,'icon differs'):self.verify()
 def test_unrelated_archive_file(self):
  with zipfile.ZipFile(self.appzip,'a') as z:z.writestr('unrelated.txt','fixture')
  with self.assertRaisesRegex(RuntimeError,'unrelated files'):self.verify()
if __name__=='__main__':unittest.main(verbosity=2)
