/*
 * Copyright (c) 2016-present Invertase Limited & Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this library except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:ansi_styles/ansi_styles.dart';

import 'common/strings.dart';
import 'common/utils.dart';
import 'firebase/firebase_app.dart';
import 'firebase/firebase_project.dart';

/// Simple check to verify Firebase Tools CLI is installed.
bool? _existsCache;
Future<bool> exists() async {
  if (_existsCache != null) {
    return _existsCache!;
  }
  final process = await Process.run(
    'firebase',
    ['--version'],
    runInShell: true,
  );
  return _existsCache = process.exitCode == 0;
}

/// Tries to read the default Firebase project id from the
/// .firbaserc file at the root of the dart project if it exists.
Future<String?> getDefaultFirebaseProjectId() async {
  final firebaseRcFile = File(firebaseRcPathForDirectory(Directory.current));
  if (!firebaseRcFile.existsSync()) return null;
  final fileContents = firebaseRcFile.readAsStringSync();
  try {
    final jsonMap =
        const JsonDecoder().convert(fileContents) as Map<String, dynamic>;
    if (jsonMap['projects'] != null &&
        (jsonMap['projects'] as Map)['default'] != null) {
      return (jsonMap['projects'] as Map)['default'] as String;
    }
  } catch (e) {
    return null;
  }
  return null;
}

/// Executes a command on the Firebase CLI and returns
/// the result as a parsed JSON Map.
/// Example:
///   final result = await runFirebaseCommand(['projects:list']);
///   print(result);
Future<Map<String, dynamic>> runFirebaseCommand(
  List<String> commandAndArgs, {
  String? project,
  String? account,
}) async {
  final cliExists = await exists();
  if (!cliExists) {
    throw FirebaseCommandException(
      '--version',
      logMissingFirebaseCli,
    );
  }
  final workingDirectoryPath = Directory.current.path;
  final execArgs = [
    ...commandAndArgs,
    '--json',
    if (project != null) '--project=$project',
    if (account != null) '--account=$account',
  ];

  final process = await Process.run(
    'firebase',
    execArgs,
    workingDirectory: workingDirectoryPath,
    runInShell: true,
  );

  final jsonString = process.stdout.toString();
  final commandResult = Map<String, dynamic>.from(
    const JsonDecoder().convert(jsonString) as Map,
  );

  if (process.exitCode > 0 || commandResult['status'] == 'error') {
    throw FirebaseCommandException(
      execArgs.join(' '),
      commandResult['error'] as String,
    );
  }

  return commandResult;
}

/// Get all available Firebase projects for the authenticated CLI user
/// or for the account provided.
Future<List<FirebaseProject>> getProjects({
  String? account,
}) async {
  final response =
      await runFirebaseCommand(['projects:list'], account: account);
  final result = List<Map<String, dynamic>>.from(response['result'] as List);
  return result
      .map<FirebaseProject>(
        (Map<String, dynamic> e) =>
            FirebaseProject.fromJson(Map<String, dynamic>.from(e)),
      )
      .where((project) => project.state == 'ACTIVE')
      .toList();
}

/// Create a new [FirebaseProject].
Future<FirebaseProject> createProject({
  required String projectId,
  String? displayName,
  String? account,
}) async {
  final response = await runFirebaseCommand(
    [
      'projects:create',
      projectId,
      if (displayName != null) displayName,
    ],
    account: account,
  );
  final result = Map<String, dynamic>.from(response['result'] as Map);
  return FirebaseProject.fromJson(<String, dynamic>{
    ...Map<String, dynamic>.from(result),
    'state': 'ACTIVE'
  });
}

/// Get registered Firebase apps for a project.
Future<List<FirebaseApp>> getApps({
  required String project,
  String? account,
  String? platform,
}) async {
  if (platform != null) _assertFirebaseSupportedPlatform(platform);
  final response = await runFirebaseCommand(
    ['apps:list', if (platform != null) platform],
    project: project,
    account: account,
  );
  final result = List<Map<String, dynamic>>.from(response['result'] as List);
  return result
      .map<FirebaseApp>(
        (Map<String, dynamic> e) =>
            FirebaseApp.fromJson(Map<String, dynamic>.from(e)),
      )
      .toList();
}

class FirebaseAppSdkConfig {
  FirebaseAppSdkConfig({
    required this.fileName,
    required this.fileContents,
  });
  final String fileName;
  final String fileContents;
}

/// Get registered Firebase apps for a project.
Future<FirebaseAppSdkConfig> getAppSdkConfig({
  required String appId,
  required String platform,
  String? account,
}) async {
  final platformFirebase = platform == kMacos ? kIos : platform;
  _assertFirebaseSupportedPlatform(platformFirebase);
  final response = await runFirebaseCommand(
    ['apps:sdkconfig', platformFirebase, appId],
    account: account,
  );
  final result = Map<String, dynamic>.from(response['result'] as Map);
  final fileContents = result['fileContents'] as String;
  final fileName = result['fileName'] as String;
  return FirebaseAppSdkConfig(
    fileName: fileName,
    fileContents: fileContents,
  );
}

void _assertFirebaseSupportedPlatform(String platformIdentifier) {
  if (![kAndroid, kWeb, kIos].contains(platformIdentifier)) {
    throw FirebasePlatformNotSupportedException(platformIdentifier);
  }
}

Future<FirebaseApp> findOrCreateFirebaseApp({
  required String platform,
  required String displayName,
  required String project,
  String? packageNameOrBundleIdentifier,
  String? account,
}) async {
  var foundFirebaseApp = false;
  final displayNameWithPlatform = '$displayName ($platform)';
  var platformFirebase = platform;
  if (platformFirebase == kMacos) platformFirebase = kIos;
  if (platformFirebase == kWindows) platformFirebase = kWeb;
  if (platformFirebase == kLinux) platformFirebase = kWeb;

  _assertFirebaseSupportedPlatform(platformFirebase);
  final fetchingAppsSpinner = spinner(
    (done) {
      final loggingAppName =
          packageNameOrBundleIdentifier ?? displayNameWithPlatform;
      if (!done) {
        return AnsiStyles.bold(
          'Fetching registered ${AnsiStyles.cyan(platform)} Firebase apps for project ${AnsiStyles.cyan(project)}',
        );
      }
      if (!foundFirebaseApp) {
        return AnsiStyles.bold(
          'Firebase ${AnsiStyles.cyan(platform)} app ${AnsiStyles.cyan(loggingAppName)} is not registered on Firebase project ${AnsiStyles.cyan(project)}.',
        );
      }
      return AnsiStyles.bold(
        'Firebase ${AnsiStyles.cyan(platform)} app ${AnsiStyles.cyan(loggingAppName)} registered.',
      );
    },
  );
  final unfilteredFirebaseApps = await getApps(
    project: project,
    account: account,
    platform: platformFirebase,
  );
  var filteredFirebaseApps = unfilteredFirebaseApps.where(
    (firebaseApp) {
      if (packageNameOrBundleIdentifier != null) {
        return firebaseApp.packageNameOrBundleIdentifier ==
                packageNameOrBundleIdentifier &&
            firebaseApp.platform == platformFirebase;
      }
      // Web has no package name or bundle identifier so we try match on
      // our generated display name.
      return firebaseApp.displayName == displayNameWithPlatform;
    },
  );

  // Try find any web app for web only. For Windows and Linux we
  // explicitly search via name only above so that named web app instances are
  // created for these platforms.
  if (platform == kWeb && filteredFirebaseApps.isEmpty) {
    filteredFirebaseApps = unfilteredFirebaseApps.where(
      (firebaseApp) {
        return firebaseApp.platform == kWeb;
      },
    );
  }
  foundFirebaseApp = filteredFirebaseApps.isNotEmpty;
  fetchingAppsSpinner.done();
  // TODO in the case of web, if more than one found app then
  // TODO we should maybe prompt to choose one.
  if (foundFirebaseApp) {
    return filteredFirebaseApps.first;
  }

  // Existing app not found so we need to create it.
  Future<FirebaseApp> createFirebaseAppFuture;
  switch (platformFirebase) {
    case kAndroid:
      createFirebaseAppFuture = createAndroidApp(
        project: project,
        displayName: displayNameWithPlatform,
        packageName: packageNameOrBundleIdentifier!,
      );
      break;
    case kIos:
      createFirebaseAppFuture = createAppleApp(
        project: project,
        displayName: displayNameWithPlatform,
        bundleId: packageNameOrBundleIdentifier!,
      );
      break;
    case kWeb:
      createFirebaseAppFuture = createWebApp(
        project: project,
        displayName: displayNameWithPlatform,
      );
      break;
    default:
      throw FlutterPlatformNotSupportedException(platform);
  }

  final creatingAppSpinner = spinner(
    (done) {
      if (!done) {
        return AnsiStyles.bold(
          'Registering new Firebase ${AnsiStyles.cyan(platform)} app on Firebase project ${AnsiStyles.cyan(project)}.',
        );
      }
      return AnsiStyles.bold(
        'Registered a new Firebase ${AnsiStyles.cyan(platform)} app on Firebase project ${AnsiStyles.cyan(project)}.',
      );
    },
  );
  final firebaseApp = await createFirebaseAppFuture;
  creatingAppSpinner.done();
  return firebaseApp;
}

/// Create a new web [FirebaseApp].
Future<FirebaseApp> createWebApp({
  required String project,
  required String displayName,
  String? account,
}) async {
  final response = await runFirebaseCommand(
    [
      'apps:create',
      'web',
      displayName,
    ],
    project: project,
    account: account,
  );
  final result = Map<String, dynamic>.from(response['result'] as Map);
  return FirebaseApp.fromJson(<String, dynamic>{
    ...Map<String, dynamic>.from(result),
    'platform': kWeb
  });
}

/// Create a new android [FirebaseApp].
Future<FirebaseApp> createAndroidApp({
  required String project,
  required String displayName,
  required String packageName,
  String? account,
}) async {
  final response = await runFirebaseCommand(
    [
      'apps:create',
      'android',
      displayName,
      '--package-name=$packageName',
    ],
    project: project,
    account: account,
  );
  final result = Map<String, dynamic>.from(response['result'] as Map);
  return FirebaseApp.fromJson(<String, dynamic>{
    ...Map<String, dynamic>.from(result),
    'platform': kAndroid
  });
}

/// Create a new iOS or macOS [FirebaseApp].
Future<FirebaseApp> createAppleApp({
  required String project,
  required String displayName,
  required String bundleId,
  String? account,
}) async {
  final response = await runFirebaseCommand(
    [
      'apps:create',
      'ios',
      displayName,
      '--bundle-id=$bundleId',
    ],
    project: project,
    account: account,
  );
  final result = Map<String, dynamic>.from(response['result'] as Map);
  return FirebaseApp.fromJson(<String, dynamic>{
    ...Map<String, dynamic>.from(result),
    'platform': kIos
  });
}
