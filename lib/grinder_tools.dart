// Copyright 2013 Google. All rights reserved. Use of this source code is
// governed by a BSD-style license that can be found in the LICENSE file.

/**
 * Commonly used tools for build scripts, including for tasks like running the
 * `pub` commands.
 */
library grinder.tools;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cli_util/cli_util.dart' as cli_util;
import 'package:which/which.dart';

import 'grinder.dart';
import 'src/run.dart' as run_lib;
import 'src/run_utils.dart';
import 'src/utils.dart';
import 'src/_mserve.dart';
import 'src/_wip.dart';

export 'src/run.dart';

final Directory BIN_DIR = new Directory('bin');
final Directory BUILD_DIR = new Directory('build');
final Directory LIB_DIR = new Directory('lib');
final Directory WEB_DIR = new Directory('web');

/**
 * Return the path to the current Dart SDK. This will return `null` if we are
 * unable to locate the Dart SDK.
 *
 * See also [getSdkDir].
 */
Directory get sdkDir => getSdkDir(grinderArgs());

/**
 * Return the path to the current Dart SDK. This will return `null` if we are
 * unable to locate the Dart SDK.
 *
 * This is an alias for the `cli_util` package's `getSdkDir()` method.
 */
Directory getSdkDir([List<String> cliArgs]) => cli_util.getSdkDir(cliArgs);

File get dartVM => joinFile(sdkDir, ['bin', _sdkBin('dart')]);

/// Run a dart [script] using [run_lib.run].
///
/// Returns the stdout.
@Deprecated('Use `Dart.run` instead.')
String runDartScript(String script,
    {List<String> arguments : const [], bool quiet: false, String packageRoot,
    String workingDirectory, int vmNewGenHeapMB, int vmOldGenHeapMB}) {
  List<String> args = [];

  if (packageRoot != null) {
    args.add('--package-root=${packageRoot}');
  }

  if (vmNewGenHeapMB != null) {
    args.add('--new_gen_heap_size=${vmNewGenHeapMB}');
  }

  if (vmOldGenHeapMB != null) {
    args.add('--old_gen_heap_size=${vmOldGenHeapMB}');
  }

  args.add(script);
  args.addAll(arguments);

  return run_lib.run(_sdkBin('dart'), arguments: args, quiet: quiet,
      workingDirectory: workingDirectory);
}

/// A default implementation of an `init` task. This task verifies that the
/// grind script is executed from the project root.
@Deprecated('the functionality of this method has been rolled into grinder startup')
void defaultInit([GrinderContext context]) { }

/// A default implementation of a `clean` task. This task deletes all generated
/// artifacts in the `build/`.
void defaultClean([GrinderContext context]) => delete(BUILD_DIR);

/**
 * Utility tasks for executing pub commands.
 */
class Pub {
  static PubGlobal _global = new PubGlobal._();

  /**
   * Run `pub get` on the current project. If [force] is true, this will execute
   * even if the pubspec.lock file is up-to-date with respect to the
   * pubspec.yaml file.
   */
  static void get({bool force: false, String workingDirectory}) {
    FileSet pubspec = new FileSet.fromFile(new File('pubspec.yaml'));
    FileSet publock = new FileSet.fromFile(new File('pubspec.lock'));

    if (force || !publock.upToDate(pubspec)) {
      _run('get', workingDirectory: workingDirectory);
    }
  }

  /**
   * Run `pub get` on the current project. If [force] is true, this will execute
   * even if the pubspec.lock file is up-to-date with respect to the
   * pubspec.yaml file.
   */
  static Future getAsync({bool force: false, String workingDirectory}) {
    FileSet pubspec = new FileSet.fromFile(new File('pubspec.yaml'));
    FileSet publock = new FileSet.fromFile(new File('pubspec.lock'));

    if (force || !publock.upToDate(pubspec)) {
      return run_lib.runAsync(_sdkBin('pub'), arguments: ['get'],
          workingDirectory: workingDirectory).then((_) => null);
    }

    return new Future.value();
  }

  /**
   * Run `pub upgrade` on the current project.
   */
  static void upgrade({String workingDirectory}) {
    _run('upgrade', workingDirectory: workingDirectory);
  }

  /**
   * Run `pub upgrade` on the current project.
   */
  static Future upgradeAsync({String workingDirectory}) {
    return run_lib.runAsync(_sdkBin('pub'), arguments: ['upgrade'],
        workingDirectory: workingDirectory).then((_) => null);
  }

  /**
   * Run `pub build` on the current project.
   *
   * The valid values for [mode] are `release` and `debug`.
   */
  static void build({
      String mode,
      List<String> directories,
      String workingDirectory,
      String outputDirectory}) {
    List args = ['build'];
    if (mode != null) args.add('--mode=${mode}');
    if (outputDirectory != null) args.add('--output=${outputDirectory}');
    if (directories != null && directories.isNotEmpty) args.addAll(directories);

    run_lib.run(_sdkBin('pub'), arguments: args,
        workingDirectory: workingDirectory);
  }

  /**
   * Run `pub build` on the current project.
   *
   * The valid values for [mode] are `release` and `debug`.
   */
  static Future buildAsync({
      String mode,
      List<String> directories,
      String workingDirectory,
      String outputDirectory}) {
    List args = ['build'];
    if (mode != null) args.add('--mode=${mode}');
    if (outputDirectory != null) args.add('--output=${outputDirectory}');
    if (directories != null && directories.isNotEmpty) args.addAll(directories);

    return run_lib.runAsync(_sdkBin('pub'), arguments: args,
        workingDirectory: workingDirectory).then((_) => null);
  }

  /// Run `pub run` on the given [package] and [script].
  ///
  /// If [script] is null it defaults to the same value as [package].
  static String run(String package,
      {List<String> arguments, String workingDirectory, String script}) {
    var scriptArg = script == null ? package : '$package:$script';
    List args = ['run', scriptArg];
    if (arguments != null) args.addAll(arguments);
    return run_lib.run(_sdkBin('pub'), arguments: args,
        workingDirectory: workingDirectory);
  }

  static String version({bool quiet: false}) => AppVersion.parse(
      _run('--version', quiet: quiet)).version;

  static PubGlobal get global => _global;

  static String _run(String command, {bool quiet: false, String workingDirectory}) {
    return run_lib.run(_sdkBin('pub'), quiet: quiet, arguments: [command],
        workingDirectory: workingDirectory);
  }
}

/// Access the `pub global` commands.
class PubGlobal {
  Set<String> _activatedPackages;

  PubGlobal._();

  /// Install a new Dart application.
  void activate(String packageName, {bool force: false}) {
    if (force || !isActivated(packageName)) {
      run_lib.run(_sdkBin('pub'), arguments: ['global', 'activate', packageName]);
      _activatedPackages.add(packageName);
    }
  }

  /// Run the given installed Dart application.
  String run(String package,
      {List<String> arguments, String workingDirectory, String script}) {
    var scriptArg = script == null ? package : '$package:$script';
    List args = ['global', 'run', scriptArg];
    if (arguments != null) args.addAll(arguments);
    return run_lib.run(_sdkBin('pub'), arguments: args,
        workingDirectory: workingDirectory);
  }

  /// Return the list of installed applications.
  List<AppVersion> list() {
    //dart_coveralls 0.1.8
    //den 0.1.3
    //discoveryapis_generator 0.6.1
    //...

    var stdout = run_lib.run(_sdkBin('pub'), arguments: ['global', 'list'], quiet: true);

    var lines = stdout.trim().split('\n');
    return lines.map((line) {
      line = line.trim();
      if (!line.contains(' ')) return new AppVersion._(line);
      var parts = line.split(' ');
      return new AppVersion._(parts.first, parts[1]);
    }).toList();
  }

  /// Returns whether the given Dart application is installed.
  bool isActivated(String packageName) {
    if (_activatedPackages == null) _initActivated();
    return _activatedPackages.contains(packageName);
  }

  void _initActivated() {
    if (_activatedPackages == null) {
      _activatedPackages = new Set();
      _activatedPackages.addAll(list().map((appVer) => appVer.name));
    }
  }
}

/// A Dart command-line application, installed via `pub global activate`.
abstract class PubApp {
  final String packageName;

  PubApp._(this.packageName);

  /// Create a new reference to a pub application; [packageName] is the same as the
  /// package name.
  factory PubApp.global(String packageName) => new _PubGlobalApp(packageName);

  /// Create a new reference to a pub application; [packageName] is the same as the
  /// package name.
  factory PubApp.local(String packageName) => new _PubLocalApp(packageName);

  bool get isGlobal;

  bool get isActivated;

  /// Install the application (run `pub global activate`). Setting [force] to
  /// try will force the activation of the package even if it is already
  /// installed.
  void activate({bool force: false});

  /// Run the application. If the application is not installed this command will
  /// first activate it.
  ///
  /// If [script] is provided, the sub-script will be run. So
  /// `new PubApp.global('grinder').run(script: 'init');` will run
  /// `grinder:init`.
  String run(List<String> arguments, {String script, String workingDirectory});

  String toString() => packageName;
}

class _PubGlobalApp extends PubApp {
  _PubGlobalApp(String packageName) : super._(packageName);

  bool get isGlobal => true;

  bool get isActivated => Pub.global.isActivated(packageName);

  void activate({bool force: false}) =>
      Pub.global.activate(packageName, force: force);

  String run(List<String> arguments, {String script, String workingDirectory}) {
    activate();

    return Pub.global.run(packageName,
        script: script,
        arguments: arguments,
        workingDirectory: workingDirectory);
  }
}

class _PubLocalApp extends PubApp {
  _PubLocalApp(String packageName) : super._(packageName);

  bool get isGlobal => false;

  // TODO: Implement: call a `Pub.isActivated/Pub.isInstalled`.
  bool get isActivated => throw new UnsupportedError('unimplemented');

  void activate({bool force: false}) { }

  String run(List<String> arguments, {String script, String workingDirectory}) {
    return Pub.run(packageName,
        script: script,
        arguments: arguments,
        workingDirectory: workingDirectory);
  }
}

/// Utility tasks for invoking dart.
class Dart {

  /// Run a dart [script] using [run_lib.run].
  ///
  /// Returns the stdout.
  static String run(String script,
      {List<String> arguments : const [], bool quiet: false,
       String packageRoot, String workingDirectory, int vmNewGenHeapMB,
       int vmOldGenHeapMB}) {
    List<String> args = [];

    if (packageRoot != null) {
      args.add('--package-root=${packageRoot}');
    }

    if (vmNewGenHeapMB != null) {
      args.add('--new_gen_heap_size=${vmNewGenHeapMB}');
    }

    if (vmOldGenHeapMB != null) {
      args.add('--old_gen_heap_size=${vmOldGenHeapMB}');
    }

    args.add(script);
    args.addAll(arguments);

    return run_lib.run(_sdkBin('dart'), arguments: args, quiet: quiet,
        workingDirectory: workingDirectory);
  }

  static String version({bool quiet: false}) {
    run_lib.run(_sdkBin('dart'), arguments: ['--version'],
        quiet: quiet);
    // The stdout does not have a stable documented format, so use the provided
    // metadata instead.
    return Platform.version.substring(0, Platform.version.indexOf(' '));
  }
}

/**
 * Utility tasks for invoking dart2js.
 */
class Dart2js {
  /**
   * Invoke a dart2js compile with the given [sourceFile] as input.
   */
  static void compile(File sourceFile,
      {Directory outDir, bool minify: false, bool csp: false}) {
    if (outDir == null) outDir = sourceFile.parent;
    File outFile = joinFile(outDir, ["${fileName(sourceFile)}.js"]);

    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    List args = [];
    if (minify) args.add('--minify');
    if (csp) args.add('--csp');
    args.add('-o${outFile.path}');
    args.add(sourceFile.path);

    run_lib.run(_sdkBin('dart2js'), arguments: args);
  }

  /**
   * Invoke a dart2js compile with the given [sourceFile] as input.
   */
  static Future compileAsync(File sourceFile,
      {Directory outDir, bool minify: false, bool csp: false}) {
    if (outDir == null) outDir = sourceFile.parent;
    File outFile = joinFile(outDir, ["${fileName(sourceFile)}.js"]);

    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    List args = [];
    if (minify) args.add('--minify');
    if (csp) args.add('--csp');
    args.add('-o${outFile.path}');
    args.add(sourceFile.path);

    return run_lib.runAsync(_sdkBin('dart2js'), arguments: args)
        .then((_) => null);
  }

  static String version({bool quiet: false}) =>
      AppVersion.parse(_run('--version', quiet: quiet)).version;

  static String _run(String command, {bool quiet: false}) =>
      run_lib.run(_sdkBin('dart2js'), quiet: quiet, arguments: [command]);
}

/**
 * Utility tasks for invoking the analyzer.
 */
class Analyzer {
  /// Analyze a single [File] or path ([String]).
  static void analyze(fileOrPath,
      {Directory packageRoot, bool fatalWarnings: false}) {
    analyzeFiles([fileOrPath], packageRoot: packageRoot,
        fatalWarnings: fatalWarnings);
  }

  /// Analyze one or more [File]s or paths ([String]).
  static void analyzeFiles(List files,
      {Directory packageRoot, bool fatalWarnings: false}) {
    List args = [];
    if (packageRoot != null) args.add('--package-root=${packageRoot.path}');
    if (fatalWarnings) args.add('--fatal-warnings');
    args.addAll(files.map((f) => f is File ? f.path : f));

    run_lib.run(_sdkBin('dartanalyzer'), arguments: args);
  }

  static String version({bool quiet: false}) => AppVersion.parse(run_lib.run(
      _sdkBin('dartanalyzer'), quiet: quiet, arguments: ['--version'])).version;
}

/**
 * A utility class to run tests for your project.
 */
class Tests {
  /**
   * Run command-line tests. You can specify the base directory (`test`), and
   * the file to run (`all.dart`).
   */
  static void runCliTests({String directory: 'test', String testFile: 'all.dart'}) {
    String file = '${directory}/${testFile}';
    log('running tests: ${file}...');
    Dart.run(file);
  }

  /**
   * Run web tests in a browser instance. You can specify the base directory
   * (`test`), and the html file to run (`index.html`).
   */
  static Future runWebTests({String directory: 'test',
       String htmlFile: 'index.html',
       Chrome browser}) {
    // Choose a random port to tell the browser to serve debug info to. If we
    // specify a fixed port the browser may fail to connect, but we'll still try
    // and create a debug connection to the port.
    int wip = 33000 + new math.Random().nextInt(10000); //9222;

    if (browser == null) {
      if (directory.startsWith('build')) {
        browser = Chrome.getBestInstalledChrome();
      } else {
        browser = Chrome.getBestInstalledChrome(preferDartium: true);
      }
    }

    if (browser == null) {
      return new Future.error('Unable to locate a Chrome install');
    }

    MicroServer server;
    BrowserInstance browserInstance;
    String url;
    ChromeTab tab;
    WipConnection connection;

    // Start a server.
    return MicroServer.start(port: 0, path: directory).then((s) {
      server = s;

      log("microserver serving '${server.path}' on ${server.urlBase}");

      // Start the browser.
      log('opening ${browser.browserPath}');

      List<String> args = ['--remote-debugging-port=${wip}'];
      if (Platform.environment['CHROME_ARGS'] != null) {
       args.addAll(Platform.environment['CHROME_ARGS'].split(' '));
      }
      url = 'http://${server.host}:${server.port}/${htmlFile}';
      return browser.launchUrl(url, args: args);
    }).then((bi) {
      browserInstance = bi;

      // Find tab.
      return new ChromeConnection(server.host, wip).getTab((tab) {
        return tab.url == url || tab.url.endsWith(htmlFile);
      }, retryFor: new Duration(seconds: 5));
    }).then((t) {
      tab = t;

      log('connected to ${tab}');

      // Connect via WIP.
      return WipConnection.connect(tab.webSocketDebuggerUrl);
    }).then((c) {
      connection = c;
      connection.console.enable();
      StreamSubscription sub;
      ResettableTimer timer;

      var teardown = () {
        sub.cancel();
        connection.close();
        browserInstance.kill();
        server.destroy();
        timer.cancel();
      };

      Completer completer = new Completer();

      timer = new ResettableTimer(new Duration(seconds: 60), () {
        teardown();
        if (!completer.isCompleted) {
          completer.completeError('tests timed out');
        }
      });

      sub = connection.console.onMessage.listen(
          (ConsoleMessageEvent event) {
        timer.reset();
        log(event.text);

        // 'tests finished - passed' or 'tests finished - failed'.
        if (event.text.contains('tests finished -')) {
          teardown();

          if (event.text.contains('tests finished - failed')) {
            completer.completeError('tests failed');
          } else {
            completer.complete();
          }
        }
      });

      return completer.future;
    });
  }
}

class Chrome {
  static Chrome getBestInstalledChrome({bool preferDartium: false}) {
    Chrome chrome;

    if (preferDartium) {
      chrome = new Dartium();
      if (chrome.exists) return chrome;
    }

    chrome = new Chrome.createChromeStable();
    if (chrome.exists) return chrome;

    chrome = new Chrome.createChromeDev();
    if (chrome.exists) return chrome;

    chrome = new Chrome.createChromium();
    if (chrome.exists) return chrome;

    if (!preferDartium) {
      chrome = new Dartium();
      if (chrome.exists) return chrome;
    }

    return null;
  }

  final String browserPath;
  Directory _tempDir;

  Chrome(this.browserPath) {
    _tempDir = Directory.systemTemp.createTempSync('userDataDir-');
  }

  Chrome.createChromeStable() : this(_chromeStablePath());
  Chrome.createChromeDev() : this(_chromeDevPath());
  Chrome.createChromium() : this(_chromiumPath());

  bool get exists => new File(browserPath).existsSync();

  void launchFile(String filePath, {bool verbose: false, Map envVars}) {
    String url;

    if (new File(filePath).existsSync()) {
      url = 'file:/' + new Directory(filePath).absolute.path;
    } else {
      url = filePath;
    }

    List<String> args = [
        '--no-default-browser-check',
        '--no-first-run',
        '--user-data-dir=${_tempDir.path}'
    ];

    if (verbose) {
      args.addAll(['--enable-logging=stderr', '--v=1']);
    }

    args.add(url);

    // TODO: This process often won't terminate, so that's a problem.
    log("starting chrome...");
    run_lib.run(browserPath, arguments: args, environment: envVars);
  }

  Future<BrowserInstance> launchUrl(String url,
      {List<String> args, bool verbose: false, Map envVars}) {
    List<String> _args = [
        '--no-default-browser-check',
        '--no-first-run',
        '--user-data-dir=${_tempDir.path}'
    ];

    if (verbose) _args.addAll(['--enable-logging=stderr', '--v=1']);
    if (args != null) _args.addAll(args);

    _args.add(url);

    return Process.start(browserPath, _args, environment: envVars)
        .then((Process process) {
      // Handle stdout.
      var stdoutLines = toLineStream(process.stdout);
      stdoutLines.listen(logStdout);

      // Handle stderr.
      var stderrLines = toLineStream(process.stderr);
      stderrLines.listen(logStderr);

      return new BrowserInstance(this, process);
    });
  }
}

class BrowserInstance {
  final Chrome browser;
  final Process process;

  int _exitCode;

  BrowserInstance(this.browser, this.process) {
    process.exitCode.then((int code) {
      _exitCode = code;
    });
  }

  int get exitCode => _exitCode;

  bool get running => _exitCode != null;

  void kill() {
    process.kill();
  }
}

/**
 * A wrapper around the Dartium browser.
 */
class Dartium extends Chrome {
  Dartium() : super(_dartiumPath());
}

class ContentShell extends Chrome {
  static String _contentShellPath() {
    final Map m = {
      "linux": "content_shell/content_shell",
      "macos": "content_shell/Content Shell.app/Contents/MacOS/Content Shell",
      "windows": "content_shell/content_shell.exe"
    };

    String sep = Platform.pathSeparator;
    String os = Platform.operatingSystem;
    String dartSdkPath = sdkDir.path;

    // Truncate any trailing /'s.
    if (dartSdkPath.endsWith(sep)) {
      dartSdkPath = dartSdkPath.substring(0, dartSdkPath.length - 1);
    }

    String path = "${dartSdkPath}${sep}..${sep}chromium${sep}${m[os]}";

    if (FileSystemEntity.isFileSync(path)) {
      return new File(path).absolute.path;
    }

    return null;
  }

  ContentShell() : super(_contentShellPath());
}

bool _sdkOnPath;

String _sdkBin(String name) {
  if (Platform.isWindows) {
    return name == 'dart' ? 'dart.exe' : '${name}.bat';
  } else if (Platform.isMacOS) {
    // If `dart` is not visible, we should join the sdk path and `bin/$name`.
    // This is only necessary in unusual circumstances, like when the script is
    // run from the Editor on macos.
    if (_sdkOnPath == null) {
      _sdkOnPath = whichSync('dart', orElse: () => null) != null;
    }

    return _sdkOnPath ? name : '${sdkDir.path}/bin/${name}';
  } else {
    return name;
  }
}

String _dartiumPath() {
  final Map m = {
    "linux": "chrome",
    "macos": "Chromium.app/Contents/MacOS/Chromium",
    "windows": "chrome.exe"
  };

  String sep = Platform.pathSeparator;
  String os = Platform.operatingSystem;
  String dartSdkPath = sdkDir.path;

  // Truncate any trailing /'s.
  if (dartSdkPath.endsWith(sep)) {
    dartSdkPath = dartSdkPath.substring(0, dartSdkPath.length - 1);
  }

  String path = "${dartSdkPath}${sep}..${sep}chromium${sep}${m[os]}";

  if (FileSystemEntity.isFileSync(path)) {
    return new File(path).absolute.path;
  }

  path = whichSync('Dartium', orElse: () => null);

  return path;
}

String _chromeStablePath() {
  if (Platform.isLinux) {
    return '/usr/bin/google-chrome';
  } else if (Platform.isMacOS) {
    return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  } else {
    List paths = [
      r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
      r"C:\Program Files\Google\Chrome\Application\chrome.exe"
    ];

    for (String path in paths) {
      if (new File(path).existsSync()) {
        return path;
      }
    }
  }

  return null;
}

String _chromeDevPath() {
  if (Platform.isLinux) {
    return '/usr/bin/google-chrome-unstable';
  } else if (Platform.isMacOS) {
    return '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary';
  } else {
    return null;
  }
}

String _chromiumPath() {
  if (Platform.isLinux) {
    return '/usr/bin/chromium-browser';
  } else if (Platform.isMacOS) {
    return '/Applications/Chromium.app/Contents/MacOS/Chromium';
  }

  return null;
}

/// A version/app name pair.
class AppVersion {
  final String name;
  final String version;

  AppVersion._(this.name, [this.version]);

  static AppVersion parse(String output) {
    var lastSpace = output.lastIndexOf(' ');
    if (lastSpace == -1) return new AppVersion._(output);
    return new AppVersion._(output.substring(0, lastSpace),
        output.substring(lastSpace + 1));
  }

  String toString() => '$name $version';
}
