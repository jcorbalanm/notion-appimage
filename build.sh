mkdir build
pushd build

curl --location https://www.notion.so/desktop/windows/download --output installer

7z e installer \$PLUGINSDIR/app-64.7z
7z x app-64.7z resources/
npx --yes @electron/asar extract resources/app.asar app

sqlite=$(node --print "require('./app/package.json').dependencies['better-sqlite3']")
electron=$(node --print "require('./app/package.json').devDependencies['electron']")

# Download better-sqlite3
# It's a git:// URL, don't bother doing it otherwise
npm pack better-sqlite3@$sqlite
tar --extract --file better-sqlite3-*.tgz

# Rebuild better-sqlite3
pushd package
npm install --no-audit
# https://www.electronjs.org/docs/latest/tutorial/using-native-node-modules#manually-building-for-electron
npx node-gyp rebuild --target=$electron --arch=x64 --dist-url=https://electronjs.org/headers
cp build/Release/better_sqlite3.node ../app/node_modules/better-sqlite3/build/Release
popd

pushd app

# Official icon is not recognized by electron builder
rm icon.ico
cp ../../assets/icon.png .

# - Patch platform detection
# - Disable auto update
sed --in-place '
	s/"win32"===process.platform/(true)/g
	s/_.Store.getState().app.preferences?.isAutoUpdaterDisabled/(true)/g
' .webpack/main/index.js

# Add tray icon support and fix process cleanup
# Inject tray icon + clean exit after the main sed patch
node --input-type=module << 'EOF'
import { readFileSync, writeFileSync } from 'fs';

const path = '.webpack/main/index.js';
let src = readFileSync(path, 'utf8');

const trayPatch = `
// === Tray icon patch ===
const { app: _trayApp, BrowserWindow: _TrayBW, Tray, Menu, nativeImage } = require('electron');
let _trayInstance = null;

function _setupTray() {
  try {
    const icon = nativeImage.createFromPath(require('path').join(__dirname, '../../icon.png'));
    _trayInstance = new Tray(icon.resize({ width: 16, height: 16 }));
    _trayInstance.setToolTip('Notion');
    _trayInstance.setContextMenu(Menu.buildFromTemplate([
      {
        label: 'Show Notion',
        click: () => {
          const wins = _TrayBW.getAllWindows();
          wins.forEach(w => { w.show(); w.focus(); });
        }
      },
      { type: 'separator' },
      {
        label: 'Quit Notion',
        click: () => { _trayApp.quit(); }
      }
    ]));
    _trayInstance.on('double-click', () => {
      const wins = _TrayBW.getAllWindows();
      wins.forEach(w => { w.show(); w.focus(); });
    });
  } catch(e) { console.error('Tray setup failed:', e); }
}

_trayApp.whenReady().then(_setupTray);

// Prevent default close from quitting — minimise to tray instead
_trayApp.on('browser-window-created', (_, win) => {
  win.on('close', (e) => {
    if (!_trayApp.isQuiting) {
      e.preventDefault();
      win.hide();
    }
  });
});

// Ensure full exit on quit
_trayApp.on('before-quit', () => { _trayApp.isQuiting = true; });
// === End tray icon patch ===
`;

// Prepend after the first 'use strict'; or at the very top
src = src.replace(/^(["']use strict["'];?\n?)/, '$1' + trayPatch + '\n');
writeFileSync(path, src);
console.log('Tray patch applied.');
EOF

# Don't let electron-builder rebuild native dependencies
# https://www.electron.build/cli
npx --yes electron-builder@25 --linux appimage --config.npmRebuild=false
popd

popd
