"""Parchea android/app/build.gradle(.kts): minSdk 24 + core library desugaring
(necesario para flutter_local_notifications)."""
import pathlib, re, sys

base = pathlib.Path('android/app')
kts, groovy = base / 'build.gradle.kts', base / 'build.gradle'

if kts.exists():
    s = kts.read_text()
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    if 'isCoreLibraryDesugaringEnabled' not in s:
        s = re.sub(r'(compileOptions\s*\{)', r'\1\n        isCoreLibraryDesugaringEnabled = true', s, count=1)
    if 'coreLibraryDesugaring(' not in s:
        s += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
    kts.write_text(s)
    print('patched', kts)
elif groovy.exists():
    s = groovy.read_text()
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    s = re.sub(r'minSdk\s*=?\s*flutter\.minSdkVersion', 'minSdk 24', s)
    if 'coreLibraryDesugaringEnabled' not in s:
        s = re.sub(r'(compileOptions\s*\{)', r'\1\n        coreLibraryDesugaringEnabled true', s, count=1)
    if 'coreLibraryDesugaring ' not in s:
        s += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
    groovy.write_text(s)
    print('patched', groovy)
else:
    sys.exit('No se encontro android/app/build.gradle(.kts)')
