remote = require 'remote'
app = remote.require('app')
async = require 'async'
exec = require('child_process').exec
fs = require 'fs-extra'
path = require 'path'
progress = require 'request-progress'
request = require 'request'
tar = require 'tar-fs'
zlib = require 'zlib'
_ = require 'lodash'

# Windows Specific Dependencies
if process.platform == 'win32'
  runas = require 'runas'

cErrors = require './errors'
hlp = require './helpers'
optionsParser = require './options_parser'
preferences = require './preferences'
pkg = require '../package.json'
viewManager = require './view_manager'


###*
 * Function Compares version numbers. Returns 1 if left is highest, -1 if right, 0 if the same.
 * @param {String} First (Left) version number.
 * @param {String} Second (Right) version number.
 * @returns {Number}.
###
versionCompare = (left, right) ->
  if typeof left + typeof right != 'stringstring'
    return false

  a = left.split('.')
  b = right.split('.')
  i = 0
  len = Math.max(a.length, b.length)

  while i < len
    if a[i] and !b[i] and parseInt(a[i]) > 0 or parseInt(a[i]) > parseInt(b[i])
      return 1
    else if b[i] and !a[i] and parseInt(b[i]) > 0 or parseInt(a[i]) < parseInt(b[i])
      return -1
    i++

  return 0


###*
 * Function Downloads update file
 * @callback {Function} Callback.
###
download = (url, download_path, done) ->
  try
    file = fs.createWriteStream(download_path)
  catch e
    error = new cErrors.UpdateError("Can\'t write update file: #{path.basename(download_path)}").causedBy(e)

    if process.platform == 'win32' and !optionsParser.runnedAsAdmin()
      return runas(process.execPath, ['--startAsAdmin'], {hide: false, admin: true})

    return done(error)

  last_percent = 0
  progress(request(url), {throttle: 500})
    .on 'progress', (state) ->
      if state.percent > last_percent
        last_percent = state.percent
        hlp.incrUIProgressBar('update_progress_bar', last_percent)
    .on 'error', (err) -> return done(err)
    .pipe(file)
    .on 'error', (err) -> return done(err)
    .on 'close', ->
      file.close()
      done()

###*
 * Function Sets up flow for download minor update (just update.asar)
 * @callback {Function} Callback.
###
minorUpdate = (version) ->
  viewManager.update()

  url = "https://github.com/dustinblackman/Championify/releases/download/#{version}/update.asar"
  app_asar = path.join(__dirname, '..')
  update_asar = path.join(__dirname, '../../', 'update-asar')

  download url, update_asar, ->
    if process.platform == 'darwin'
      osxMinor(app_asar, update_asar)
    else
      winMinor(app_asar, update_asar)


###*
 * Function Sets up flow for download major update (replacing entire install directory)
 * @callback {Function} Callback.
###
majorUpdate = (version) ->
  viewManager.update()

  if process.platform == 'darwin'
    platform = 'OSX'
    install_path = path.join(__dirname, '../../../../')
    tar_name = 'u_osx.tar.gz'
  else
    platform = 'WIN'
    install_path = path.join(__dirname, '../../../')
    tar_name = 'u_win.tar.gz'

  tar_path = path.join(preferences.directory(), tar_name)
  install_path = install_path.substring(0, install_path.length - 1)
  update_path = path.join(preferences.directory(), 'major_update')

  url = "https://github.com/dustinblackman/Championify/releases/download/#{version}/#{tar_name}"

  async.series [
    (step) -> # Delete previous update folder if exists
      if fs.existsSync(update_path)
        fs.remove update_path, (err) ->
          step(new cErrors.UpdateError('Can\'t remove previous update path').causedBy(err))
      else
        step()
    (step) -> # Download Tarball
      download url, tar_path, (err) ->
        return step(new cErrors.UpdateError('Can\'t write/download update file').causedBy(err)) if err
        step()
    (step) -> # Extract Tarball
      $('#update_current_file').text("#{T.t('extracting')}")
      stream = fs.createReadStream(tar_path)
        .pipe(zlib.Gunzip())
        .pipe(tar.extract(update_path))
      stream.on 'error', (err) ->
        return step(new cErrors.UpdateError('Can\'t extract update').causedBy(err)) if err
      stream.on 'finish', ->
        step()
    (step) -> # Delete Tarball
      fs.unlink tar_path, (err) ->
        return step(new cErrors.UpdateError('Can\'t unlink major update zip').causedBy(err)) if err
        step()
  ], (err) ->
    return EndSession(err) if err

    if process.platform == 'darwin'
      osxMajor(install_path, update_path)
    else
      winMajor(install_path, update_path)


###*
 * Function Reboots Championify for minor updates on OSX
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdaets
###
osxMinor = (app_asar, update_asar) ->
  fs.unlink app_asar, (err) ->
    return EndSession(new cErrors.UpdateError('Can\'t unlink file').causedBy(err)) if err

    fs.rename update_asar, app_asar, (err) ->
      return EndSession(new cErrors.UpdateError('Can\'t rename app.asar').causedBy(err)) if err

      appPath = __dirname.replace('/Contents/Resources/app.asar/js', '')
      exec 'open -n ' + appPath
      setTimeout ->
        app.quit()
      , 250


###*
 * Function Reboots Championify for major updates on OSX
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdaets
###
osxMajor = (install_path, update_path) ->
  cmd = _.template([
    'echo -n -e "\\033]0;Updating ${name}\\007"'
    'echo Updating ${name}, please wait...'
    'killall ${name}'
    'mv "${update_path}/Contents/Resources/atom-asar" "${update_path}/Contents/Resources/atom.asar"'
    'mv "${update_path}/Contents/Resources/app-asar" "${update_path}/Contents/Resources/app.asar"'
    'rm -rf "${install_path}"'
    'mv "${update_path}" "${install_path}"'
    'open -n "${install_path}"'
    'exit'
  ].join('\n'))

  update_path = path.join(update_path, 'Championify.app')

  params = {
    install_path: install_path
    update_path: update_path
    name: pkg.name
  }
  update_file = path.join(preferences.directory(), 'update_major.sh')

  fs.writeFile update_file, cmd(params), 'utf8', (err) ->
    return EndSession(new cErrors.UpdateError('Can\'t write update_major.sh').causedBy(err)) if err

    exec 'bash "' + update_file + '"'


###*
 * Function Reboots Championify for updates on Windows
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdates
###
winMinor = (app_asar, update_asar) ->
  cmd = _.template('
    @echo off\n
    title Updating Championify
    echo Updating Championify, please wait...\n
    taskkill /IM ${process_name} /f\n
    ping 1.1.1.1 -n 1 -w 1000 > nul\n
    del "${app_asar}"\n
    ren "${update_asar}" app.asar\n
    start "" "${exec_path}"\n
    exit\n
  ')

  params = {
    app_asar: app_asar
    update_asar: update_asar
    exec_path: process.execPath
    process_name: path.basename(process.execPath)
  }

  update_file = path.join(preferences.directory(), 'update.bat')

  fs.writeFile update_file, cmd(params), 'utf8', (err) ->
    return EndSession(new cErrors.UpdateError('Can\'t write update.bat').causedBy(err)) if err
    exec "START \"\" \"#{update_file}\""


###*
 * Function Reboots Championify for major updates on Windows
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdates
###
winMajor = (install_path, update_path) ->
  cmd = _.template([
    '@echo off'
    'title Updating Championify'
    'echo Updating Championify, please wait...'
    'taskkill /IM ${process_name} /f'
    'ping 1.1.1.1 -n 1 -w 1000 > nul'
    'ren "${update_path}\\resources\\app-asar" app.asar'
    'ren "${update_path}\\resources\\atom-asar" atom.asar'
    'rmdir "${install_path}" /s /q'
    'move "${update_path}" "${root_path}"'
    'start "" "${exec_path}"'
    'exit'
  ].join('\n'))

  # TODO: Get path of where the app is installed to be used when re-executing, instead of defaulting to 'Championify'.

  update_path = path.join(update_path, 'Championify')
  root_path = path.resolve(path.join(install_path, '../'))

  params = {
    install_path: install_path
    update_path: update_path
    root_path: root_path
    exec_path: process.execPath
    process_name: path.basename(process.execPath)
  }

  update_file = path.join(preferences.directory(), 'update_major.bat')

  fs.writeFile update_file, cmd(params), 'utf8', (err) ->
    return EndSession(new cErrors.FileWriteError('Can\'t write update_major.bat').causedBy(err)) if err
    runas(process.execPath, ['--winMajor'], {hide: false, admin: true})


###*
 * Function Check version of Github package.json and local. Executes update if available.
  * @callback {Function} Callback, only accepts a single finished parameter as errors are handled with endSession.
###
check = (done) ->
  # If local version is using 0.26.0 of electron, it means it doesn't have the correct support for the major auto update.
  if process.versions.electron == '0.26.0'
    return viewManager.breakingChanges()

  url = 'https://raw.githubusercontent.com/dustinblackman/Championify/master/package.json'
  hlp.request url, (err, data) ->
    return EndSession(new cErrors.RequestError('Can\'t access Github package.json').causedBy(err)) if err

    if versionCompare(data.devDependencies['electron-prebuilt'], process.versions.electron) == 1
      return done(data.version, true)
    else if versionCompare(data.version, pkg.version) == 1
      return done(data.version)
    else
      return done(null)


module.exports = {
  check: check
  minorUpdate: minorUpdate
  majorUpdate: majorUpdate
}
