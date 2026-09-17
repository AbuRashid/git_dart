import 'hooks.dart';

/// A browser cannot run a program, so there is never one to find.
String? findHookProgram(String directory, String name) => null;

HookResult runHookSync(String program, HookInvocation invocation) =>
    throw UnsupportedError('hooks cannot be run in a browser');

Future<HookResult> runHook(String program, HookInvocation invocation) =>
    throw UnsupportedError('hooks cannot be run in a browser');
