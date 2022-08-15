import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

// ignore_for_file: invalid_null_aware_operator

/// SupabaseAuth
class SupabaseAuth with WidgetsBindingObserver {
  SupabaseAuth._();

  static final SupabaseAuth _instance = SupabaseAuth._();

  bool _initialized = false;
  late LocalStorage _localStorage;

  /// The [LocalStorage] instance used to persist the user session.
  LocalStorage get localStorage => _localStorage;

  /// {@macro supabase.localstorage.hasAccessToken}
  Future<bool> get hasAccessToken => _localStorage.hasAccessToken();

  /// {@macro supabase.localstorage.accessToken}
  Future<String?> get accessToken => _localStorage.accessToken();

  /// Returns when the initial session recovery is done.
  ///
  /// Can be used to determine whether a user is signed in upon initial
  /// app launch.
  Future<Session?> get initialSession => _initialSessionCompleter.future;
  final Completer<Session?> _initialSessionCompleter = Completer();

  /// **ATTENTION**: `getInitialLink`/`getInitialUri` should be handled
  /// ONLY ONCE in your app's lifetime, since it is not meant to change
  /// throughout your app's life.
  bool _initialDeeplinkIsHandled = false;
  String? _authCallbackUrlHostname;

  GotrueSubscription? _authSubscription;
  final _listenerController = StreamController<AuthChangeEvent>.broadcast();

  StreamSubscription<Uri?>? _deeplinkSubscription;

  final _appLinks = AppLinks();

  /// Listen to auth change events.
  ///
  /// ```dart
  /// SupabaseAuth.instance.onAuthChange.listen((event) {
  ///   // Handle event
  /// });
  /// ```
  ///
  /// A new event is fired when:
  ///
  ///   * the user is logged in
  ///   * the user signs out
  ///   * the user info is updated
  ///   * the user password is recovered
  Stream<AuthChangeEvent> get onAuthChange => _listenerController.stream;

  /// A [SupabaseAuth] instance.
  ///
  /// If not initialized, an [AssertionError] is thrown
  static SupabaseAuth get instance {
    assert(
      _instance._initialized,
      'You must initialize the supabase instance before calling Supabase.instance',
    );

    return _instance;
  }

  /// Initialize the [SupabaseAuth] instance.
  ///
  /// It's necessary to initialize before calling [SupabaseAuth.instance]
  static Future<SupabaseAuth> initialize({
    LocalStorage localStorage = const HiveLocalStorage(),
    String? authCallbackUrlHostname,
  }) async {
    try {
      _instance._initialized = true;
      _instance._localStorage = localStorage;
      _instance._authCallbackUrlHostname = authCallbackUrlHostname;

      _instance._authSubscription =
          Supabase.instance.client.auth.onAuthStateChange((event, session) {
        _instance._onAuthStateChange(event, session);
        if (!_instance._listenerController.isClosed) {
          _instance._listenerController.add(event);
        }
      });

      await _instance._localStorage.initialize();

      final hasPersistedSession =
          await _instance._localStorage.hasAccessToken();
      if (hasPersistedSession) {
        final persistedSession = await _instance._localStorage.accessToken();
        if (persistedSession != null) {
          try {
            final response = await Supabase.instance.client.auth
                .recoverSession(persistedSession);
            if (!_instance._initialSessionCompleter.isCompleted) {
              _instance._initialSessionCompleter.complete(response.session);
            }
          } on GoTrueException catch (error) {
            Supabase.instance.log(error.message);
            if (!_instance._initialSessionCompleter.isCompleted) {
              _instance._initialSessionCompleter.completeError(error);
            }
          } catch (error) {
            Supabase.instance.log(error.toString());
            if (!_instance._initialSessionCompleter.isCompleted) {
              _instance._initialSessionCompleter.completeError(error);
            }
          }
        }
      }
      WidgetsBinding.instance.addObserver(_instance);
      _instance._startDeeplinkObserver();

      if (!_instance._initialSessionCompleter.isCompleted) {
        // Complete with null if the user did not have persisted session
        _instance._initialSessionCompleter.complete(null);
      }
      return _instance;
    } catch (error, stacktrace) {
      if (!_instance._initialSessionCompleter.isCompleted) {
        _instance._initialSessionCompleter.completeError(error, stacktrace);
      }
      rethrow;
    }
  }

  /// Dispose the instance to free up resources
  void dispose() {
    _listenerController.close();
    _authSubscription?.data?.unsubscribe();
    _stopDeeplinkObserver();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _recoverSupabaseSession();
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Recover/refresh session if it's available
  /// e.g. called on a Splash screen when app starts.
  Future<bool> _recoverSupabaseSession() async {
    final bool exist = await SupabaseAuth.instance.localStorage.hasAccessToken();
    if (!exist) {
      return false;
    }

    final String? jsonStr = await SupabaseAuth.instance.localStorage.accessToken();
    if (jsonStr == null) {
      return false;
    }

    try {
      await Supabase.instance.client.auth.recoverSession(jsonStr);
      return true;
    } catch (error) {
      SupabaseAuth.instance.localStorage.removePersistedSession();
      return false;
    }
  }

  void _onAuthStateChange(AuthChangeEvent event, Session? session) {
    Supabase.instance.log('**** onAuthStateChange: $event');
    if (event == AuthChangeEvent.signedIn && session != null) {
      Supabase.instance.log(session.persistSessionString);
      _localStorage.persistSession(session.persistSessionString);
    } else if (event == AuthChangeEvent.signedOut) {
      _localStorage.removePersistedSession();
    }
  }

  /// if _authCallbackUrlHost not init, we treat all deeplink as auth callback
  bool _isAuthCallbackDeeplink(Uri uri) {
    if (_authCallbackUrlHostname == null) {
      return true;
    } else {
      return _authCallbackUrlHostname == uri.host;
    }
  }

  /// Enable deep link observer to handle deep links
  void _startDeeplinkObserver() {
    Supabase.instance.log('***** SupabaseDeepLinkingMixin startAuthObserver');
    _handleIncomingLinks();
    _handleInitialUri();
  }

  /// Stop deep link observer
  ///
  /// Automatically called on dispose().
  void _stopDeeplinkObserver() {
    Supabase.instance.log('***** SupabaseDeepLinkingMixin stopAuthObserver');
    _deeplinkSubscription?.cancel();
  }

  /// Handle incoming links - the ones that the app will recieve from the OS
  /// while already started.
  void _handleIncomingLinks() {
    if (!kIsWeb) {
      // It will handle app links while the app is already started - be it in
      // the foreground or in the background.
      _deeplinkSubscription = _appLinks.uriLinkStream.listen(
        (Uri? uri) {
          if (uri != null) {
            _handleDeeplink(uri);
          }
        },
        onError: (Object err) {
          _onErrorReceivingDeeplink(err.toString());
        },
      );
    }
  }

  /// Handle the initial Uri - the one the app was started with
  ///
  /// **ATTENTION**: `getInitialLink`/`getInitialUri` should be handled
  /// ONLY ONCE in your app's lifetime, since it is not meant to change
  /// throughout your app's life.
  ///
  /// We handle all exceptions, since it is called from initState.
  Future<void> _handleInitialUri() async {
    if (_initialDeeplinkIsHandled) return;
    _initialDeeplinkIsHandled = true;

    try {
      final uri = await _appLinks.getInitialAppLink();
      if (uri != null) {
        _handleDeeplink(uri);
      }
    } on PlatformException catch (err) {
      _onErrorReceivingDeeplink(err.message ?? err.toString());
      // Platform messages may fail but we ignore the exception
    } on FormatException catch (err) {
      _onErrorReceivingDeeplink(err.message);
    } catch (err) {
      _onErrorReceivingDeeplink(err.toString());
    }
  }

  /// Callback when deeplink receiving succeeds
  Future<void> _handleDeeplink(Uri uri) async {
    if (!_instance._isAuthCallbackDeeplink(uri)) return;

    Supabase.instance.log('***** SupabaseAuthState handleDeeplink $uri');

    // notify auth deeplink received
    Supabase.instance.log('onReceivedAuthDeeplink uri: $uri');

    await _recoverSessionFromUrl(uri);
  }

  Future<void> _recoverSessionFromUrl(Uri uri) async {
    // recover session from deeplink
    try {
      await Supabase.instance.client.auth.getSessionFromUrl(uri);
    } on GoTrueException catch (error) {
      Supabase.instance.log(error.message);
    } catch (error) {
      Supabase.instance.log(error.toString());
    }
  }

  /// Callback when deeplink receiving throw error
  void _onErrorReceivingDeeplink(String message) {
    Supabase.instance.log('onErrorReceivingDeppLink message: $message');
  }
}

extension GoTrueClientSignInProvider on GoTrueClient {
  /// Signs the user in using a thrid parties providers.
  ///
  /// See also:
  ///
  ///   * <https://supabase.io/docs/guides/auth#third-party-logins>
  Future<bool> signInWithProvider(
    Provider provider, {
    AuthOptions? options,
  }) async {
    final res = await signIn(
      provider: provider,
      options: options,
    );
    final url = Uri.parse(res.url!);
    final result = await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_self',
    );
    return result;
  }
}
