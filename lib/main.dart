import 'dart:math';
import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:local_auth/local_auth.dart';

// ============================================
// CONFIGURATION
// ============================================
const String kVpsBase       = 'https://api.tchipa.co.uk';
const String kAgentTelegram = 'https://t.me/c/3983752002/1';
const double kExchangeRate  = 242.0;

class UserProfile {
  static String name = '';
  static String phone = '';
  static String email = '';
  // Local mirror of /auth/pin-status. Once true, the device knows the user
  // completed PIN setup + email verification for this phone, so we stop
  // prompting at startup. The backend remains the source of truth — if a
  // claim fails with PIN_NOT_SET we re-trigger the setup flow.
  static bool pinSet = false;

  static bool get isEmpty =>
      name.trim().isEmpty || phone.trim().isEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    name  = prefs.getString('profile_name')  ?? '';
    phone = prefs.getString('profile_phone') ?? '';
    email = prefs.getString('profile_email') ?? '';
    pinSet = prefs.getBool('profile_pin_set') ?? false;
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_name',  name);
    await prefs.setString('profile_phone', phone);
    await prefs.setString('profile_email', email);
    await prefs.setBool('profile_pin_set', pinSet);
  }
}

// ============================================
// PIN SETUP HELPER — orchestrates setup + email verification UX
// ============================================
class PinSetup {
  // Full first-time flow: confirm we don't already have a verified PIN,
  // collect a 4-digit PIN, send the magic link, then block on a polling
  // "check your email" dialog until the user confirms or cancels.
  // Returns true if pinSet is now true.
  static Future<bool> run(BuildContext context) async {
    final phone = UserProfile.phone.trim();
    final email = UserProfile.email.trim();
    if (phone.isEmpty || email.isEmpty) return false;

    // Reconcile with backend: maybe this device reinstalled and the PIN
    // is already set on this phone server-side.
    try {
      final status = await PinApi.authPinStatus(phone);
      if (status.exists && status.verified) {
        UserProfile.pinSet = true;
        await UserProfile.save();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('PIN déjà configuré pour ce numéro.'),
          ));
        }
        return true;
      }
    } catch (_) { /* network — let user retry via the dialog */ }

    if (!context.mounted) return false;
    final pin = await _askForNewPin(context);
    if (pin == null) return false;

    if (!context.mounted) return false;
    try {
      await PinApi.authSetupPin(phone: phone, email: email, pin: pin);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ));
      }
      return false;
    }

    if (!context.mounted) return false;
    final verified = await _awaitEmailVerification(context, phone: phone, email: email);
    if (verified) {
      UserProfile.pinSet = true;
      await UserProfile.save();
    }
    return verified;
  }

  // Change-PIN flow — assumes pinSet=true. Asks for old PIN + new PIN twice.
  static Future<void> changePinDialog(BuildContext context) async {
    final phone = UserProfile.phone.trim();
    if (phone.isEmpty) return;
    final oldPinCtrl = TextEditingController();
    final newPinCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? errorMsg;
    bool busy = false;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setDlg) {
        Future<void> submit() async {
          final oldPin = oldPinCtrl.text.trim();
          final newPin = newPinCtrl.text.trim();
          final confirm = confirmCtrl.text.trim();
          if (!RegExp(r'^\d{4,6}$').hasMatch(oldPin)) {
            setDlg(() => errorMsg = 'Ancien PIN invalide');
            return;
          }
          if (!RegExp(r'^\d{4,6}$').hasMatch(newPin)) {
            setDlg(() => errorMsg = 'Nouveau PIN: 4 à 6 chiffres');
            return;
          }
          if (newPin != confirm) {
            setDlg(() => errorMsg = 'Confirmation différente');
            return;
          }
          setDlg(() { busy = true; errorMsg = null; });
          try {
            await PinApi.authChangePin(phone: phone, oldPin: oldPin, newPin: newPin);
            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
          } catch (e) {
            setDlg(() { busy = false; errorMsg = e.toString().replaceFirst('Exception: ', ''); });
          }
        }
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Changer mon PIN'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            _pinField(oldPinCtrl, hint: 'Ancien PIN', enabled: !busy),
            const SizedBox(height: 12),
            _pinField(newPinCtrl, hint: 'Nouveau PIN', enabled: !busy),
            const SizedBox(height: 12),
            _pinField(confirmCtrl, hint: 'Confirmer', enabled: !busy),
            if (errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(errorMsg!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(dialogCtx).pop(),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Enregistrer'),
            ),
          ],
        );
      }),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('PIN mis à jour'),
      ));
    }
  }

  // ----- internals -----

  static Future<String?> _askForNewPin(BuildContext context) async {
    final pinCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? errorMsg;
    String? result;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setDlg) {
        Future<void> submit() async {
          final pin = pinCtrl.text.trim();
          final confirm = confirmCtrl.text.trim();
          if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
            setDlg(() => errorMsg = 'PIN: 4 à 6 chiffres');
            return;
          }
          if (pin != confirm) {
            setDlg(() => errorMsg = 'Confirmation différente');
            return;
          }
          result = pin;
          if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
        }
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Crée ton PIN Tchipa'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Ce PIN est ton secret. Seul toi peux récupérer une carte envoyée à ton numéro. '
              'Ne le partage avec personne, pas même un agent.',
              style: TextStyle(color: AppColors.textSub, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            _pinField(pinCtrl, hint: 'PIN à 4 chiffres', enabled: true),
            const SizedBox(height: 12),
            _pinField(confirmCtrl, hint: 'Confirmer', enabled: true),
            if (errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(errorMsg!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Annuler'),
            ),
            ElevatedButton(onPressed: submit, child: const Text('Continuer')),
          ],
        );
      }),
    );
    return result;
  }

  // Shows a "check your email" panel and polls /auth/pin-status until
  // verified or cancelled. Auto-poll every 4s for up to ~10 minutes.
  static Future<bool> _awaitEmailVerification(
      BuildContext context, {required String phone, required String email}) async {
    bool verified = false;
    Timer? pollTimer;
    String? errorMsg;
    bool busy = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setDlg) {
        Future<void> checkNow() async {
          setDlg(() { busy = true; errorMsg = null; });
          try {
            final s = await PinApi.authPinStatus(phone);
            if (s.exists && s.verified) {
              verified = true;
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
              return;
            }
            setDlg(() { busy = false; errorMsg = 'Email pas encore vérifié.'; });
          } catch (e) {
            setDlg(() { busy = false; errorMsg = e.toString().replaceFirst('Exception: ', ''); });
          }
        }
        pollTimer ??= Timer.periodic(const Duration(seconds: 4), (_) async {
          try {
            final s = await PinApi.authPinStatus(phone);
            if (s.exists && s.verified) {
              verified = true;
              pollTimer?.cancel();
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            }
          } catch (_) {}
        });
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Vérifie ton email'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mark_email_unread_rounded,
                color: const Color(0xFF00D4FF), size: 48),
            const SizedBox(height: 12),
            Text(
              'On t\'a envoyé un lien à\n$email\n\nClique-le, puis reviens ici.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSub, fontSize: 13),
            ),
            if (errorMsg != null) ...[
              const SizedBox(height: 8),
              Text(errorMsg!, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      pollTimer?.cancel();
                      Navigator.of(dialogCtx).pop();
                    },
              child: const Text('Plus tard'),
            ),
            ElevatedButton(
              onPressed: busy ? null : checkNow,
              child: busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('J\'ai cliqué'),
            ),
          ],
        );
      }),
    );
    pollTimer?.cancel();
    return verified;
  }

  static Widget _pinField(TextEditingController c, {required String hint, required bool enabled}) {
    return TextField(
      controller: c,
      enabled: enabled,
      autofocus: true,
      keyboardType: TextInputType.number,
      obscureText: true,
      maxLength: 6,
      textAlign: TextAlign.center,
      style: TextStyle(color: AppColors.inputFg, fontSize: 20, letterSpacing: 6),
      decoration: InputDecoration(counterText: '', hintText: hint),
    );
  }
}

// ============================================
// PIN API (/auth/*) — PIN du solde Tchipa
// ============================================
class PinApi {
  // ----- /auth/* — PIN setup + email magic-link -----

  // Triggers a magic-link email. The backend stores the PIN hash immediately
  // but marks the row unverified until the link is clicked. Throws on
  // PIN_ALREADY_SET so the UI can route to change-pin instead.
  static Future<void> authSetupPin({
    required String phone,
    required String email,
    required String pin,
    String? deviceId,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kVpsBase/auth/setup-pin'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone': phone,
            'email': email,
            'pin':   pin,
            if (deviceId != null) 'device_id': deviceId,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) return;
    throw Exception(body['message']?.toString() ?? body['error']?.toString() ?? 'Erreur setup PIN (${resp.statusCode})');
  }

  static Future<({bool exists, bool verified, String? email})> authPinStatus(String phone) async {
    final resp = await http
        .get(Uri.parse('$kVpsBase/auth/pin-status?phone=${Uri.encodeComponent(phone)}'))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Erreur statut PIN');
    }
    return (
      exists:   body['exists'] == true,
      verified: body['verified'] == true,
      email:    body['email']?.toString(),
    );
  }

  static Future<void> authChangePin({
    required String phone,
    required String oldPin,
    required String newPin,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kVpsBase/auth/change-pin'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'phone': phone, 'old_pin': oldPin, 'new_pin': newPin}),
        )
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) return;
    throw Exception(body['error']?.toString() ?? 'Erreur changement PIN (${resp.statusCode})');
  }
}

final ValueNotifier<bool>   darkModeNotifier = ValueNotifier(true);
final ValueNotifier<String> langNotifier     = ValueNotifier('fr');

class AppSettings {
  static const _kDark = 'dark_mode';
  static const _kLang = 'app_lang';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    darkModeNotifier.value = p.getBool(_kDark) ?? true;
    langNotifier.value     = p.getString(_kLang) ?? 'fr';
    AppColors.update(darkModeNotifier.value);
  }

  static Future<void> setDark(bool v) async {
    darkModeNotifier.value = v;
    AppColors.update(v);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDark, v);
  }

  static Future<void> setLang(String v) async {
    langNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLang, v);
  }
}

// ============================================
// SEMANTIC COLORS (theme-aware)
// ============================================
class AppColors {
  static Color bg       = const Color(0xFF0D1117);
  static Color surface  = const Color(0xFF0F1923);
  static Color card     = const Color(0xFF1A2332);
  static Color text     = Colors.white;
  static Color textSub  = Colors.white60;
  static Color textDim  = Colors.white38;
  static Color border   = const Color(0xFF1A2332);
  // Adaptive helpers — always readable on bg/surface/card
  static Color label    = Colors.white;       // primary label on bg
  static Color sublabel = Colors.white60;     // secondary label
  static Color hint     = Colors.white38;     // placeholder / hint
  static Color inputFg  = Colors.white;       // text-field input text
  static Color navUnsel = Colors.white38;     // unselected nav icon/label
  static bool  isDark   = true;

  static void update(bool dark) {
    isDark = dark;
    if (dark) {
      bg       = const Color(0xFF0D1117);
      surface  = const Color(0xFF0F1923);
      card     = const Color(0xFF1A2332);
      text     = Colors.white;
      textSub  = Colors.white60;
      textDim  = Colors.white38;
      border   = const Color(0xFF2A3347);
      label    = Colors.white;
      sublabel = Colors.white60;
      hint     = Colors.white38;
      inputFg  = Colors.white;
      navUnsel = Colors.white38;
    } else {
      bg       = const Color(0xFFF0F5FF);
      surface  = const Color(0xFFFFFFFF);
      card     = const Color(0xFFEAF0FB);
      text     = const Color(0xFF0D1117);
      textSub  = const Color(0xFF334155);
      textDim  = const Color(0xFF64748B);
      border   = const Color(0xFFD1DCF0);
      label    = const Color(0xFF0D1117);
      sublabel = const Color(0xFF334155);
      hint     = const Color(0xFF94A3B8);
      inputFg  = const Color(0xFF0D1117);
      navUnsel = const Color(0xFF64748B);
    }
  }
}

// ============================================
// TRANSLATIONS (FR / AR)
// ============================================
class _L {
  final String activate;
  final String activateSubtitle;
  final String chooseAmount;
  final String payDirectly;
  final String sendExactly;
  final String usdtPolygonOnly;
  final String exactAmount;
  final String usdtAddress;
  final String addressCopied;
  final String polygonWarning;
  final String paidVerify;
  final String orderCreated;
  final String newVccCard;
  final String checking;
  final String cardReady;
  final String newCardActivated;
  final String viewCard;
  final String close;
  final String paymentReceived;
  final String paymentNotReceived;
  final String recharge;
  final String createOrder;
  final String myProfile;
  final String saveProfile;
  final String biometric;
  final String biometricSub;
  final String agentMode;
  final String settings;
  final String language;
  final String theme;
  final String lightMode;
  final String darkMode;
  final String french;
  final String arabic;
  final String home;
  final String transactions;
  final String profile;
  final String activate2;
  final String activated;
  final String cardActive;
  final String activateCard;
  final String cardReady2;
  final String cardActivated;
  final String mastercard;
  final String cardNetwork;

  const _L({
    required this.activate,
    required this.activateSubtitle,
    required this.chooseAmount,
    required this.payDirectly,
    required this.sendExactly,
    required this.usdtPolygonOnly,
    required this.exactAmount,
    required this.usdtAddress,
    required this.addressCopied,
    required this.polygonWarning,
    required this.paidVerify,
    required this.orderCreated,
    required this.newVccCard,
    required this.checking,
    required this.cardReady,
    required this.newCardActivated,
    required this.viewCard,
    required this.close,
    required this.paymentReceived,
    required this.paymentNotReceived,
    required this.recharge,
    required this.createOrder,
    required this.myProfile,
    required this.saveProfile,
    required this.biometric,
    required this.biometricSub,
    required this.agentMode,
    required this.settings,
    required this.language,
    required this.theme,
    required this.lightMode,
    required this.darkMode,
    required this.french,
    required this.arabic,
    required this.home,
    required this.transactions,
    required this.profile,
    required this.activate2,
    required this.activated,
    required this.cardActive,
    required this.activateCard,
    required this.cardReady2,
    required this.cardActivated,
    required this.mastercard,
    required this.cardNetwork,
  });
}

const _fr = _L(
  activate: 'Activer ma carte',
  activateSubtitle: 'Paiement direct USDT · Réseau Polygon',
  chooseAmount: 'Choisir le montant de la carte',
  payDirectly: 'Payez directement en USDT sur le réseau Polygon',
  sendExactly: 'Envoyez exactement',
  usdtPolygonOnly: 'USDT sur le réseau Polygon uniquement',
  exactAmount: 'MONTANT EXACT À ENVOYER',
  usdtAddress: 'ADRESSE USDT (POLYGON)',
  addressCopied: 'Adresse copiée',
  polygonWarning: '⚠ Envoyez uniquement sur le réseau Polygon. Tout envoi sur un autre réseau sera perdu.',
  paidVerify: 'J\'ai payé — Vérifier',
  orderCreated: 'Commande créée',
  newVccCard: 'Nouvelle carte VCC',
  checking: 'Vérification du paiement…',
  cardReady: 'Carte prête !',
  newCardActivated: 'Votre nouvelle carte VCC Mastercard est activée.',
  viewCard: 'Voir ma carte',
  close: 'Fermer',
  paymentReceived: 'Paiement reçu — carte en cours d\'émission, revérifiez dans 1 min.',
  paymentNotReceived: 'Paiement non reçu. Vérifiez que vous avez envoyé exactement',
  recharge: 'Nouvelle carte',
  createOrder: 'Créer ma commande',
  myProfile: 'Mon profil',
  saveProfile: 'Enregistrer',
  biometric: 'Protection biométrique',
  biometricSub: 'Empreinte / Face ID au démarrage',
  agentMode: 'Mode Agent',
  settings: 'Paramètres',
  language: 'Langue',
  theme: 'Thème',
  lightMode: 'Mode clair',
  darkMode: 'Mode sombre',
  french: 'Français',
  arabic: 'العربية',
  home: 'Accueil',
  transactions: 'Transactions',
  profile: 'Profil',
  activate2: 'Activer',
  activated: 'Activée',
  cardActive: 'Carte active · Paiements internationaux',
  activateCard: 'Activez votre carte pour commencer',
  cardReady2: 'Carte activée !',
  cardActivated: 'Votre carte VCC Mastercard est prête.',
  mastercard: 'Carte Mastercard',
  cardNetwork: 'réseau Polygon',
);

const _ar = _L(
  activate: 'تفعيل البطاقة',
  activateSubtitle: 'دفع مباشر بـ USDT · شبكة Polygon',
  chooseAmount: 'اختر قيمة البطاقة',
  payDirectly: 'ادفع مباشرةً بـ USDT على شبكة Polygon',
  sendExactly: 'أرسل بالضبط',
  usdtPolygonOnly: 'USDT على شبكة Polygon فقط',
  exactAmount: 'المبلغ الدقيق للإرسال',
  usdtAddress: 'عنوان USDT (Polygon)',
  addressCopied: 'تم نسخ العنوان',
  polygonWarning: '⚠ أرسل فقط على شبكة Polygon. أي إرسال على شبكة أخرى سيُفقد.',
  paidVerify: 'دفعت — تحقق',
  orderCreated: 'تم إنشاء الطلب',
  newVccCard: 'بطاقة VCC جديدة',
  checking: 'جارٍ التحقق من الدفع…',
  cardReady: 'البطاقة جاهزة!',
  newCardActivated: 'بطاقة Mastercard VCC الجديدة مُفعَّلة.',
  viewCard: 'عرض البطاقة',
  close: 'إغلاق',
  paymentReceived: 'تم استلام الدفع — يتم إصدار البطاقة، تحقق خلال دقيقة.',
  paymentNotReceived: 'لم يُستلم الدفع. تأكد من إرسال بالضبط',
  recharge: 'بطاقة جديدة',
  createOrder: 'إنشاء طلب',
  myProfile: 'ملفي الشخصي',
  saveProfile: 'حفظ',
  biometric: 'الحماية البيومترية',
  biometricSub: 'بصمة الإصبع / Face ID عند التشغيل',
  agentMode: 'وضع الوكيل',
  settings: 'الإعدادات',
  language: 'اللغة',
  theme: 'المظهر',
  lightMode: 'المظهر الفاتح',
  darkMode: 'المظهر الداكن',
  french: 'Français',
  arabic: 'العربية',
  home: 'الرئيسية',
  transactions: 'المعاملات',
  profile: 'الملف',
  activate2: 'تفعيل',
  activated: 'مُفعَّلة',
  cardActive: 'بطاقة نشطة · مدفوعات دولية',
  activateCard: 'فعّل بطاقتك للبدء',
  cardReady2: 'تم تفعيل البطاقة!',
  cardActivated: 'بطاقة VCC Mastercard جاهزة.',
  mastercard: 'بطاقة Mastercard',
  cardNetwork: 'شبكة Polygon',
);

_L get L => langNotifier.value == 'ar' ? _ar : _fr;

// ============================================
// APP LOCK (biometric / device credentials)
// ============================================
class AppLock {
  static const _kEnabled = 'app_lock_enabled';

  static Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  static Future<bool> authenticate(BuildContext context) async {
    final auth = LocalAuthentication();
    try {
      final available = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!available) return true;
      return await auth.authenticate(
        localizedReason: 'Authentifiez-vous pour accéder à Tchipa',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return true;
    }
  }
}

// ============================================
// LOCK SCREEN
// ============================================
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _tryAuth() async {
    setState(() { _loading = true; _error = null; });
    final ok = await AppLock.authenticate(context);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainScreen(),
          transitionDuration: const Duration(milliseconds: 400),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    } else {
      setState(() { _loading = false; _error = 'Authentification refusée'; });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAuth());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Center(
                child: Text('T', style: TextStyle(color: Colors.black, fontSize: 40,
                    fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 32),
            const Text('Tchipa', style: TextStyle(color: Colors.white, fontSize: 28,
                fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Veuillez vous authentifier',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14)),
            const SizedBox(height: 40),
            if (_loading)
              const CircularProgressIndicator(color: Color(0xFF00D4FF))
            else ...[
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                const SizedBox(height: 16),
              ],
              GestureDetector(
                onTap: _tryAuth,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fingerprint_rounded, color: Colors.black, size: 22),
                      SizedBox(width: 10),
                      Text('S\'authentifier', style: TextStyle(color: Colors.black,
                          fontWeight: FontWeight.bold, fontSize: 15)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserProfile.load();
  await AppSettings.load();
  await ShopApi.load();
  await Cart.load();
  runApp(const TchipaApp());
}

// ============================================
// APP
// ============================================
class TchipaApp extends StatelessWidget {
  const TchipaApp({super.key});

  ThemeData _buildTheme(bool dark) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: AppColors.bg,
      primaryColor: const Color(0xFF00D4FF),
      cardColor: AppColors.surface,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00D4FF),
        brightness: brightness,
        surface: AppColors.surface,
        onSurface: AppColors.text,
      ),
      fontFamily: 'SF Pro Display',
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF00D4FF)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: TextStyle(color: AppColors.textDim),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([darkModeNotifier, langNotifier]),
      builder: (_, __) {
        final isAr = langNotifier.value == 'ar';
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Tchipa',
          locale: Locale(langNotifier.value),
          supportedLocales: const [Locale('fr'), Locale('ar')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: _buildTheme(darkModeNotifier.value),
          builder: (ctx, child) => Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const SplashScreen(),
        );
      },
    );
  }
}

// ============================================
// SPLASH SCREEN
// ============================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _flagCtrl;
  late Animation<double> _flagAnim;
  late AnimationController _logoSpinCtrl;
  late AnimationController _logoPulseCtrl;
  late Animation<double> _logoPulse;
  late AnimationController _imgCtrl;
  late Animation<double> _imgFade;
  late AnimationController _overlayCtrl;
  late Animation<double> _overlayFade;
  late Animation<Offset> _overlaySlide;

  @override
  void initState() {
    super.initState();
    _flagCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
    _flagAnim =
        Tween<double>(begin: 0, end: 2 * pi).animate(_flagCtrl);
    _logoSpinCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 9))
      ..repeat();
    _logoPulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat(reverse: true);
    _logoPulse = Tween<double>(begin: 0.94, end: 1.06).animate(
        CurvedAnimation(parent: _logoPulseCtrl, curve: Curves.easeInOut));

    _imgCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900));
    _imgFade =
        CurvedAnimation(parent: _imgCtrl, curve: Curves.easeIn);

    _overlayCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600));
    _overlayFade = CurvedAnimation(
        parent: _overlayCtrl, curve: Curves.easeIn);
    _overlaySlide = Tween<Offset>(
            begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _overlayCtrl, curve: Curves.easeOut));

    _imgCtrl.forward().then((_) => _overlayCtrl.forward());
    Future.delayed(const Duration(milliseconds: 3200), () async {
      if (!mounted) return;
      final lockEnabled = await AppLock.isEnabled();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            lockEnabled ? const LockScreen() : const MainScreen(),
        transitionDuration: const Duration(milliseconds: 600),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ));
    });
  }

  @override
  void dispose() {
    _flagCtrl.dispose();
    _logoSpinCtrl.dispose();
    _logoPulseCtrl.dispose();
    _imgCtrl.dispose();
    _overlayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Center(
          child: FadeTransition(
            opacity: _imgFade,
            child: SizedBox(
              width: 280, height: 280,
              child: Stack(alignment: Alignment.center, children: [
                AnimatedBuilder(
                  animation: _flagCtrl,
                  builder: (_, __) => CustomPaint(
                    size: const Size(280, 280),
                    painter: _ElectricLogoPainter(_flagAnim.value),
                  ),
                ),
                // Rotating + breathing Tchipa "T" mark, centered inside the
                // electric-arc painter. The arcs spin in their own frame; the
                // logo spins on itself at a slower cadence with a gentle pulse.
                AnimatedBuilder(
                  animation: Listenable.merge([_logoSpinCtrl, _logoPulseCtrl]),
                  builder: (_, __) {
                    return Transform.scale(
                      scale: _logoPulse.value,
                      child: Transform.rotate(
                        angle: _logoSpinCtrl.value * 2 * pi,
                        child: Container(
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x5900D4FF),
                                blurRadius: 40,
                                spreadRadius: 8,
                              ),
                              BoxShadow(
                                color: Color(0x338B5CF6),
                                blurRadius: 60,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Image.asset(
                            'assets/tchipa_logo.png',
                            width: 150, height: 150,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ]),
            ),
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 0,
          height: size.height * 0.45,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.85),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 52,
          child: SlideTransition(
            position: _overlaySlide,
            child: FadeTransition(
              opacity: _overlayFade,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                    ).createShader(b),
                    child: const Text('tchipa',
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 8,
                        )),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Carte Virtuelle · Paiements Sécurisés',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 28, height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFF00D4FF)
                              .withValues(alpha: 0.8)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ============================================
// MAIN SCREEN (3-tab shell)
// ============================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _idx = 0;
  // Boutique first: PayGate/Swype cards are gone (2026-09), the shop is the product.
  static const _screens = [
    ShopScreen(),
    WalletScreen(),
    OrdersScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    if (UserProfile.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _idx = 3);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.person_outline, color: Color(0xFF00D4FF)),
            const SizedBox(width: 10),
            Text('Complétez votre profil pour commencer',
                style: TextStyle(color: AppColors.label)),
          ]),
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _idx, children: _screens),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              height: 68,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: AppColors.isDark ? 0.82 : 0.92),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.8), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 24, offset: const Offset(0, 8)),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _NavPill(icon: Icons.storefront_rounded,   label: 'Boutique',  sel: _idx == 0, onTap: () => setState(() => _idx = 0)),
                  _NavPill(icon: Icons.account_balance_wallet_rounded, label: 'Solde', sel: _idx == 1, onTap: () => setState(() => _idx = 1)),
                  _NavPill(icon: Icons.local_shipping_rounded, label: 'Commandes', sel: _idx == 2, onTap: () => setState(() => _idx = 2)),
                  _NavPill(icon: Icons.person_rounded,       label: 'Profil',    sel: _idx == 3, onTap: () => setState(() => _idx = 3)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool sel;
  final VoidCallback onTap;
  const _NavPill({required this.icon, required this.label, required this.sel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: EdgeInsets.symmetric(horizontal: sel ? 18 : 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: sel ? const LinearGradient(
            colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
          ) : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20,
                color: sel ? Colors.white : AppColors.navUnsel),
            if (sel) ...[
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _emailCtrl;
  bool _saving = false;
  bool _lockEnabled = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl  = TextEditingController(text: UserProfile.name);
    _phoneCtrl = TextEditingController(text: UserProfile.phone);
    _emailCtrl = TextEditingController(text: UserProfile.email);
    AppLock.isEnabled().then((v) { if (mounted) setState(() => _lockEnabled = v); });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    UserProfile.name  = _nameCtrl.text.trim();
    UserProfile.phone = _phoneCtrl.text.trim();
    UserProfile.email = _emailCtrl.text.trim();
    await UserProfile.save();
    setState(() => _saving = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Row(children: [
        Icon(Icons.check_circle_rounded, color: Color(0xFF00D4FF)),
        SizedBox(width: 10),
        Text('Profil enregistré',
            style: TextStyle(color: Colors.white)),
      ]),
      backgroundColor: AppColors.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 2),
    ));
    // First save with phone+email but no PIN yet → walk the user through
    // setup immediately. Agent transactions require a verified PIN, so
    // surfacing this proactively avoids "ton PIN n'est pas configuré"
    // surprises later.
    if (!UserProfile.pinSet &&
        UserProfile.phone.trim().isNotEmpty &&
        UserProfile.email.trim().isNotEmpty) {
      await PinSetup.run(context);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final initial = UserProfile.name.isNotEmpty
        ? UserProfile.name[0].toUpperCase()
        : '?';
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Mon profil',
            style: TextStyle(
                color: AppColors.label, fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 80, height: 80,
                  margin: const EdgeInsets.symmetric(vertical: 20),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [
                      Color(0xFF00D4FF), Color(0xFF8B5CF6)
                    ]),
                  ),
                  child: Center(
                    child: Text(initial,
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 30,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const _FieldLabel('Nom complet *'),
              TextFormField(
                controller: _nameCtrl,
                style: TextStyle(color: AppColors.inputFg),
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Prénom Nom',
                  hintStyle: TextStyle(color: AppColors.hint),
                ),
                validator: (v) =>
                    v?.trim().isEmpty == true ? 'Requis' : null,
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Téléphone *'),
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppColors.inputFg),
                decoration: InputDecoration(
                  hintText: '+213 XXX XXX XXX',
                  hintStyle: TextStyle(color: AppColors.hint),
                ),
                validator: (v) =>
                    v?.trim().isEmpty == true ? 'Requis' : null,
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Email *'),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: AppColors.inputFg),
                decoration: InputDecoration(
                  hintText: 'vous@email.com',
                  hintStyle: TextStyle(color: AppColors.hint),
                ),
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return 'Requis';
                  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s)) return 'Email invalide';
                  return null;
                },
              ),
              const SizedBox(height: 32),
              _GradButton(label: 'Enregistrer', busy: _saving, onTap: _save),
              const SizedBox(height: 28),
              Text(L.settings,
                  style: TextStyle(color: AppColors.textSub, fontSize: 12,
                      fontWeight: FontWeight.w600, letterSpacing: 1.2)),
              const SizedBox(height: 12),
              // — Langue
              _SettingsTile(
                icon: Icons.language_rounded,
                title: L.language,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _LangBtn('FR', langNotifier.value == 'fr', () async {
                    await AppSettings.setLang('fr');
                    if (mounted) setState(() {});
                  }),
                  const SizedBox(width: 8),
                  _LangBtn('AR', langNotifier.value == 'ar', () async {
                    await AppSettings.setLang('ar');
                    if (mounted) setState(() {});
                  }),
                ]),
              ),
              const SizedBox(height: 10),
              // — Thème
              _SettingsTile(
                icon: darkModeNotifier.value
                    ? Icons.dark_mode_rounded
                    : Icons.light_mode_rounded,
                title: darkModeNotifier.value ? L.darkMode : L.lightMode,
                trailing: Switch(
                  value: !darkModeNotifier.value,
                  onChanged: (v) async {
                    await AppSettings.setDark(!v);
                    if (mounted) setState(() {});
                  },
                  thumbColor: WidgetStateProperty.all(const Color(0xFF00D4FF)),
                  trackColor: WidgetStateProperty.all(const Color(0xFF00D4FF).withValues(alpha: 0.3)),
                ),
              ),
              // — Biométrique (native only: local_auth has no web plugin, and
              // an app-lock toggle that can never actually lock would mislead)
              if (!kIsWeb) ...[
              const SizedBox(height: 10),
              _SettingsTile(
                icon: Icons.fingerprint_rounded,
                title: L.biometric,
                subtitle: L.biometricSub,
                trailing: Switch(
                  value: _lockEnabled,
                  onChanged: (v) async {
                    if (v) {
                      final ok = await AppLock.authenticate(context);
                      if (!ok) return;
                    }
                    await AppLock.setEnabled(v);
                    if (mounted) setState(() => _lockEnabled = v);
                  },
                  thumbColor: WidgetStateProperty.all(const Color(0xFF00D4FF)),
                  trackColor: WidgetStateProperty.all(const Color(0xFF00D4FF).withValues(alpha: 0.3)),
                ),
              ),
              ],
              const SizedBox(height: 10),
              // — PIN de réception carte (gate /cards/claim-with-pin)
              _SettingsTile(
                icon: Icons.lock_outline_rounded,
                title: UserProfile.pinSet
                    ? 'Changer mon PIN Tchipa'
                    : 'Configurer mon PIN Tchipa',
                subtitle: UserProfile.pinSet
                    ? 'PIN vérifié — seul toi peux récupérer les cartes envoyées à ton numéro.'
                    : 'Obligatoire pour recevoir une carte d\'un agent. Email + PIN à 4 chiffres.',
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFF00D4FF)),
                onTap: () async {
                  if (UserProfile.phone.trim().isEmpty ||
                      UserProfile.email.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Renseigne et enregistre ton téléphone + email d\'abord.'),
                    ));
                    return;
                  }
                  if (UserProfile.pinSet) {
                    await PinSetup.changePinDialog(context);
                  } else {
                    await PinSetup.run(context);
                  }
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AgentWalletScreen())),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0xFF8B5CF6).withValues(alpha: 0.30)),
                    borderRadius: BorderRadius.circular(14),
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.06),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.support_agent_rounded,
                          color: Color(0xFF8B5CF6), size: 18),
                      SizedBox(width: 10),
                      Text('Espace agent — créditer un client',
                          style: TextStyle(
                              color: Color(0xFF8B5CF6),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  const _SettingsTile({required this.icon, required this.title,
      this.subtitle, required this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Icon(icon, color: const Color(0xFF00D4FF), size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: AppColors.text, fontSize: 14,
                fontWeight: FontWeight.w600)),
            if (subtitle != null)
              Text(subtitle!, style: TextStyle(color: AppColors.textDim, fontSize: 11)),
          ]),
        ),
        trailing,
      ]),
    );
    if (onTap == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: tile,
    );
  }
}

class _LangBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LangBtn(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          gradient: selected ? const LinearGradient(
              colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]) : null,
          color: selected ? null : AppColors.card,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: TextStyle(
            color: selected ? Colors.black : AppColors.textSub,
            fontWeight: FontWeight.bold, fontSize: 13)),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              letterSpacing: 0.5)),
    );
  }
}

// ============================================
// ELECTRIC LOGO PAINTER
// ============================================
class _ElectricLogoPainter extends CustomPainter {
  final double phase;
  _ElectricLogoPainter(this.phase);

  // Precomputed arc offsets seeded at 42 — always same shape, animated by phase
  static final List<List<Offset>> _arcs = [];

  static List<List<Offset>> _buildArcs(double r0, double r1) {
    if (_arcs.isNotEmpty) return _arcs;
    final rng = Random(42);
    for (int arc = 0; arc < 12; arc++) {
      final baseAngle = (arc / 12) * 2 * pi;
      final pts = <Offset>[];
      double r = r0;
      double a = baseAngle;
      while (r < r1) {
        pts.add(Offset(cos(a) * r, sin(a) * r));
        r += 5 + rng.nextDouble() * 7;
        a += (rng.nextDouble() - 0.5) * 0.55;
      }
      pts.add(Offset(cos(a) * r1, sin(a) * r1));
      _arcs.add(pts);
    }
    return _arcs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);
    final short = size.shortestSide;
    final r0 = short * 0.30;
    final r1 = short * 0.50;
    final t = phase / (2 * pi); // 0..1

    final arcs = _buildArcs(r0, r1);

    // ── Pulsing concentric rings ──
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (int i = 0; i < 5; i++) {
      final rt = (t + i * 0.2) % 1.0;
      final radius = r0 + rt * (r1 + short * 0.12 - r0);
      final opacity = (1 - rt) * 0.5;
      ringPaint.color = const Color(0xFF00D4FF).withValues(alpha: opacity);
      canvas.drawCircle(center, radius, ringPaint);
    }

    // ── Electric arcs ──
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < arcs.length; i++) {
      final arcT = (t * 4 + i / arcs.length) % 1.0;
      final opacity = arcT < 0.5 ? arcT * 2 : (1 - arcT) * 2;
      final isBlue = i % 3 != 0;
      arcPaint.color = (isBlue
              ? const Color(0xFF00D4FF)
              : const Color(0xFF8B5CF6))
          .withValues(alpha: (opacity * 0.85).clamp(0.0, 1.0));

      final pts = arcs[i];
      final path = Path()..moveTo(center.dx + pts[0].dx, center.dy + pts[0].dy);
      for (int j = 1; j < pts.length; j++) {
        path.lineTo(center.dx + pts[j].dx, center.dy + pts[j].dy);
      }
      canvas.drawPath(path, arcPaint);

      // Spark at tip
      final tip = Offset(center.dx + pts.last.dx, center.dy + pts.last.dy);
      canvas.drawCircle(
        tip,
        2.5,
        Paint()
          ..color = const Color(0xFF00D4FF).withValues(alpha: opacity * 0.9)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }

    // ── Rotating dashed orbit ring ──
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0xFF00D4FF).withValues(alpha: 0.18);
    canvas.drawCircle(center, r0 - 4, orbitPaint);

    // ── Orbiting electron dots ──
    for (int d = 0; d < 3; d++) {
      final angle = phase + d * 2 * pi / 3;
      final pos = Offset(center.dx + cos(angle) * (r0 - 4),
          center.dy + sin(angle) * (r0 - 4));
      canvas.drawCircle(
        pos,
        4.5,
        Paint()
          ..color = const Color(0xFF00D4FF).withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(pos, 2.0,
          Paint()..color = const Color(0xFF00D4FF).withValues(alpha: 0.95));
      canvas.drawCircle(pos, 0.8,
          Paint()..color = Colors.white.withValues(alpha: 0.9));
    }

    // ── Central glow halo ──
    final glow = (sin(phase * 2.3) + 1) * 0.5;
    canvas.drawCircle(
      center,
      r0 * 0.85,
      Paint()
        ..color = const Color(0xFF00D4FF).withValues(alpha: 0.06 + glow * 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
  }

  @override
  bool shouldRepaint(_ElectricLogoPainter old) => old.phase != phase;
}

// ============================================
// BOUTIQUE 1688 + PORTE-MONNAIE $ (2026-09-28)
// ============================================
// PayGate/Swype are gone: Tchipa now sells clothes (1688 catalogue) paid with
// a USD balance. The balance is credited by a human agent (dinars via
// BaridiMob). Server routes: /shop/*, /wallet/*, /agent/* in backend/server.js.
// The app never sends a price — the server charges the chosen variant's price.

const LinearGradient _kShopGrad =
    LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]);

String _usd(num v) => '${v.toStringAsFixed(2)} \$';

String _idemKey() {
  final r = Random.secure();
  return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
}

String _thumb(String? url) =>
    url == null ? '' : (url.contains('alicdn.com') ? '${url}_300x300.jpg' : url);

class ApiError implements Exception {
  final int status;
  final String message;
  final Map<String, dynamic> body;
  ApiError(this.status, this.message, this.body);
  @override
  String toString() => message;
}

class ShopApi {
  static const _tokKey = 'wallet_token', _agentKey = 'agent_token';
  static String? walletToken;
  static String? agentToken;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    walletToken = p.getString(_tokKey);
    agentToken = p.getString(_agentKey);
  }

  static Future<void> _save(String k, String? v) async {
    final p = await SharedPreferences.getInstance();
    if (v == null) {
      await p.remove(k);
    } else {
      await p.setString(k, v);
    }
  }

  static Future<Map<String, dynamic>> _req(String method, String path,
      {Map<String, dynamic>? body, String? bearer}) async {
    final uri = Uri.parse('$kVpsBase$path');
    final h = {
      'Content-Type': 'application/json',
      if (bearer != null) 'Authorization': 'Bearer $bearer',
    };
    http.Response r;
    try {
      r = method == 'GET'
          ? await http.get(uri, headers: h).timeout(const Duration(seconds: 25))
          : await http
              .post(uri, headers: h, body: jsonEncode(body ?? {}))
              .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw ApiError(0, 'Le serveur ne répond pas. Réessaie dans un instant.', {});
    } catch (_) {
      throw ApiError(0, 'Pas de connexion internet.', {});
    }
    Map<String, dynamic> d;
    try {
      d = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      d = {};
    }
    if (r.statusCode >= 400) {
      if (r.statusCode == 401 && bearer != null && bearer == walletToken) {
        walletToken = null;
        await _save(_tokKey, null);
      }
      throw ApiError(r.statusCode, (d['error'] ?? 'Erreur ${r.statusCode}').toString(), d);
    }
    return d;
  }

  // Client wallet
  static bool get loggedIn => walletToken != null;
  static Future<double> login(String phone, String pin) async {
    final d = await _req('POST', '/wallet/login', body: {'phone': phone, 'pin': pin});
    walletToken = d['token'] as String;
    await _save(_tokKey, walletToken);
    return (d['balanceUsd'] as num).toDouble();
  }

  static Future<Map<String, dynamic>> me() => _req('GET', '/wallet/me', bearer: walletToken);

  static Future<void> logout() async {
    try {
      await _req('POST', '/wallet/logout', bearer: walletToken);
    } catch (_) {}
    walletToken = null;
    await _save(_tokKey, null);
  }

  // Shop
  static Future<List<dynamic>> categories() async =>
      (await _req('GET', '/shop/categories'))['categories'] as List;

  static Future<Map<String, dynamic>> products(
      {String? category, String? sub, String q = '', String sort = 'pop', double? max, int page = 1}) {
    final qs = {
      'page': '$page',
      'sort': sort,
      if (category != null) 'category': category,
      if (sub != null) 'sub': sub,
      if (max != null) 'max': '$max',
      if (q.trim().isNotEmpty) 'q': q.trim(),
    };
    return _req('GET', '/shop/products?${Uri(queryParameters: qs).query}');
  }

  static Future<Map<String, dynamic>> product(int id) => _req('GET', '/shop/products/$id');

  static Future<Map<String, dynamic>> placeOrder(
          List<CartLine> lines, Map<String, String> delivery, String idem) =>
      _req('POST', '/shop/orders', bearer: walletToken, body: {
        'items': lines
            .map((l) => {'productId': l.productId, 'variant': l.variant, 'qty': l.qty})
            .toList(),
        'delivery': delivery,
        'idempotencyKey': idem,
      });

  static Future<List<dynamic>> myOrders() async =>
      (await _req('GET', '/shop/orders', bearer: walletToken))['orders'] as List;

  // Agent
  static Future<Map<String, dynamic>> agentMe([String? token]) =>
      _req('GET', '/agent/me', bearer: token ?? agentToken);

  static Future<void> setAgentToken(String? t) async {
    agentToken = t;
    await _save(_agentKey, t);
  }

  static Future<Map<String, dynamic>> agentCredit(
          {required String phone,
          required String amount,
          int? dzd,
          String? ref,
          required String idem}) =>
      _req('POST', '/agent/wallet/credit', bearer: agentToken, body: {
        'phone': phone,
        'amountUsd': amount,
        if (dzd != null) 'dzd': dzd,
        if (ref != null && ref.isNotEmpty) 'ref': ref,
        'idempotencyKey': idem,
      });

  static Future<List<dynamic>> agentCredits() async =>
      (await _req('GET', '/agent/credits', bearer: agentToken))['credits'] as List;
}

// ── Panier (persisté sur le téléphone) ──────────────────────────────────
class CartLine {
  final int productId;
  final String title;
  final String? image;
  final String variant; // 1688 props_names, ex. "Color:Black;Size:L"
  final Map<String, dynamic> props;
  final double unitUsd; // prix affiché ; le serveur recalcule au paiement
  int qty;
  CartLine({
    required this.productId,
    required this.title,
    required this.image,
    required this.variant,
    required this.props,
    required this.unitUsd,
    this.qty = 1,
  });

  Map<String, dynamic> toJson() => {
        'productId': productId, 'title': title, 'image': image, 'variant': variant,
        'props': props, 'unitUsd': unitUsd, 'qty': qty,
      };

  factory CartLine.fromJson(Map<String, dynamic> j) => CartLine(
        productId: j['productId'] as int,
        title: j['title'] as String,
        image: j['image'] as String?,
        variant: j['variant'] as String,
        props: Map<String, dynamic>.from(j['props'] as Map? ?? {}),
        unitUsd: (j['unitUsd'] as num).toDouble(),
        qty: j['qty'] as int,
      );

  String get variantLabel => props.values.join(' · ');
}

class Cart {
  static final ValueNotifier<List<CartLine>> lines = ValueNotifier(<CartLine>[]);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(p.getString('cart_v1') ?? '[]') as List;
      lines.value = raw.map((e) => CartLine.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      lines.value = [];
    }
  }

  static Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('cart_v1', jsonEncode(lines.value.map((l) => l.toJson()).toList()));
  }

  static void add(CartLine l) {
    final list = List.of(lines.value);
    final i = list.indexWhere((x) => x.productId == l.productId && x.variant == l.variant);
    if (i >= 0) {
      list[i].qty = min(10, list[i].qty + l.qty);
    } else {
      list.add(l);
    }
    lines.value = list;
    _persist();
  }

  static void setQty(CartLine l, int q) {
    if (q <= 0) return remove(l);
    l.qty = min(10, q);
    lines.value = List.of(lines.value);
    _persist();
  }

  static void remove(CartLine l) {
    lines.value = List.of(lines.value)..remove(l);
    _persist();
  }

  static void clear() {
    lines.value = [];
    _persist();
  }

  static int get count => lines.value.fold(0, (s, l) => s + l.qty);
  static double get total => lines.value.fold(0.0, (s, l) => s + l.unitUsd * l.qty);
}

// ── Petits éléments partagés ─────────────────────────────────────────────
class _GradButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  const _GradButton({required this.label, required this.onTap, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(gradient: _kShopGrad, borderRadius: BorderRadius.circular(16)),
          child: busy
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

InputDecoration _field(String label, {String? hint, IconData? icon}) => InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon, color: AppColors.hint, size: 20),
      labelStyle: TextStyle(color: AppColors.sublabel),
      hintStyle: TextStyle(color: AppColors.hint),
      filled: true,
      fillColor: AppColors.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    );

void _toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? const Color(0xFFB42318) : null,
    behavior: SnackBarBehavior.floating,
  ));
}

Widget _netImage(String? url, {BoxFit fit = BoxFit.cover, bool thumb = true}) {
  if (url == null || url.isEmpty) return Container(color: AppColors.card);
  Widget ph(BuildContext c, String u) => Container(color: AppColors.card);
  return CachedNetworkImage(
    imageUrl: thumb ? _thumb(url) : url,
    fit: fit,
    fadeInDuration: const Duration(milliseconds: 180),
    placeholder: ph,
    errorWidget: (c, u, e) => thumb
        ? CachedNetworkImage(imageUrl: url, fit: fit, placeholder: ph, errorWidget: (c2, u2, e2) => ph(c2, u2))
        : ph(c, u),
  );
}

class _CartButton extends StatelessWidget {
  const _CartButton();
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CartLine>>(
      valueListenable: Cart.lines,
      builder: (_, __, ___) => GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CartScreen())),
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14)),
            child: Icon(Icons.shopping_bag_outlined, color: AppColors.label),
          ),
          if (Cart.count > 0)
            Positioned(
              right: -4, top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(gradient: _kShopGrad, borderRadius: BorderRadius.circular(10)),
                child: Text('${Cart.count}',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── Connexion au solde (téléphone + PIN créé à l'installation) ──────────
Future<bool> showWalletLogin(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => const _WalletLoginSheet(),
  );
  return ok == true;
}

class _WalletLoginSheet extends StatefulWidget {
  const _WalletLoginSheet();
  @override
  State<_WalletLoginSheet> createState() => _WalletLoginSheetState();
}

class _WalletLoginSheetState extends State<_WalletLoginSheet> {
  final _phone = TextEditingController(text: UserProfile.phone);
  final _pin = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _go() async {
    setState(() { _busy = true; _err = null; });
    try {
      await ShopApi.login(_phone.text.trim(), _pin.text.trim());
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      var msg = e.message;
      if (e.status == 403 && e.body['attemptsRemaining'] != null) {
        msg = 'PIN incorrect — encore ${e.body['attemptsRemaining']} essai(s).';
      } else if (e.status == 409) {
        msg = "Ce numéro n'a pas encore de PIN Tchipa. Crée-le dans l'onglet Profil.";
      }
      setState(() => _err = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Mon solde Tchipa',
            style: TextStyle(color: AppColors.label, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('Connecte-toi avec ton numéro et ton PIN Tchipa.',
            style: TextStyle(color: AppColors.sublabel)),
        const SizedBox(height: 16),
        TextField(controller: _phone, keyboardType: TextInputType.phone,
            style: TextStyle(color: AppColors.inputFg),
            decoration: _field('Téléphone', icon: Icons.phone_rounded)),
        const SizedBox(height: 10),
        TextField(controller: _pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 8,
            style: TextStyle(color: AppColors.inputFg),
            decoration: _field('PIN', icon: Icons.lock_rounded)),
        if (_err != null)
          Padding(padding: const EdgeInsets.only(bottom: 10),
              child: Text(_err!, style: const TextStyle(color: Color(0xFFF97066)))),
        _GradButton(label: 'Se connecter', busy: _busy, onTap: _go),
      ]),
    );
  }
}

// ── Onglet Boutique ──────────────────────────────────────────────────────
// Accueil (« Tout ») : bannières, univers Femme/Homme/Enfants, meilleures ventes,
// petits prix, puis une grille sans fin. Un univers choisi : ses sous-catégories
// en vignettes rondes, tri, grille. Tout vient de /shop/categories et /shop/products.
const _kShopSorts = {'pop': 'Populaires', 'price_asc': 'Prix croissant', 'price_desc': 'Prix décroissant'};

String _soldLabel(num n) {
  if (n >= 10000) return '${(n / 1000).round()}k vendus';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1).replaceAll('.0', '')}k vendus';
  return '${n.toInt()} vendus';
}

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});
  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  List<dynamic> _cats = [];
  String? _cat, _sub;
  String _sort = 'pop';
  final List<dynamic> _items = [];
  List<dynamic> _best = [], _cheap = [];
  int _page = 0, _gen = 0;
  bool _hasMore = true, _loading = false;
  String? _err;

  bool get _home => _cat == null && _search.text.trim().isEmpty;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 900) _more();
    });
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    setState(() { _items.clear(); _page = 0; _hasMore = true; _err = null; _loading = false; });
    if (_cats.isEmpty) {
      try {
        final c = await ShopApi.categories();
        if (mounted) setState(() => _cats = c);
      } catch (_) {}
    }
    if (_home && _best.isEmpty) {
      ShopApi.products(sort: 'pop').then((d) {
        if (mounted) setState(() => _best = d['items'] as List);
      }).catchError((_) {});
      ShopApi.products(sort: 'pop', max: 5).then((d) {
        if (mounted) setState(() => _cheap = d['items'] as List);
      }).catchError((_) {});
    }
    if (gen == _gen) await _more();
  }

  Future<void> _more() async {
    if (_loading || !_hasMore) return;
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final d = await ShopApi.products(
          category: _cat, sub: _sub, q: _search.text, sort: _sort, page: _page + (_home ? 2 : 1));
      if (!mounted || gen != _gen) return;
      setState(() {
        _items.addAll(d['items'] as List);
        _page++;
        _hasMore = d['hasMore'] == true;
      });
    } on ApiError catch (e) {
      if (mounted && gen == _gen) setState(() => _err = e.message);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  void _openCat(String? c, {String? sub}) {
    _cat = c;
    _sub = sub;
    _sort = 'pop';
    _search.clear();
    FocusScope.of(context).unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _reload();
  }

  Map<String, dynamic>? get _catData {
    for (final c in _cats) {
      if (c['name'] == _cat) return Map<String, dynamic>.from(c as Map);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: const Color(0xFF8B5CF6),
          onRefresh: () async {
            _best = [];
            _cheap = [];
            _cats = [];
            await _reload();
          },
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverToBoxAdapter(child: _header()),
            SliverPersistentHeader(pinned: true, delegate: _PinnedBar(height: 54, child: _catTabs())),
            if (_home) ..._homeSlivers() else ..._listingHeader(),
            if (_err != null && _items.isEmpty)
              SliverToBoxAdapter(child: _errorBox()),
            if (!_home || _items.isNotEmpty || _loading)
              SliverToBoxAdapter(
                child: _home
                    ? _sectionTitle('Pour toi', 'Les plus achetés cette semaine')
                    : const SizedBox(height: 4),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, mainAxisSpacing: 14, crossAxisSpacing: 12, childAspectRatio: 0.58),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => i < _items.length
                      ? _ProductTile(p: _items[i] as Map<String, dynamic>)
                      : const _TileSkeleton(),
                  childCount: _items.length + (_loading ? (_items.isEmpty ? 6 : 2) : 0),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 18, bottom: 130),
                child: Center(
                  child: (!_hasMore && _items.isEmpty && _err == null && !_loading)
                      ? Column(children: [
                          Icon(Icons.search_off_rounded, size: 46, color: AppColors.hint),
                          const SizedBox(height: 8),
                          Text('Aucun article trouvé', style: TextStyle(color: AppColors.sublabel)),
                        ])
                      : (!_hasMore && _items.isNotEmpty
                          ? Text('Tu as tout vu ✨', style: TextStyle(color: AppColors.hint, fontSize: 12.5))
                          : const SizedBox.shrink()),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── En-tête : marque + panier, puis recherche ──
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
      child: Column(children: [
        Row(children: [
          ShaderMask(
            shaderCallback: (r) => _kShopGrad.createShader(r),
            child: const Text('Tchipa',
                style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
            child: const Text('Boutique',
                style: TextStyle(color: Color(0xFF8B5CF6), fontSize: 11, fontWeight: FontWeight.w800)),
          ),
          const Spacer(),
          const _CartButton(),
        ]),
        const SizedBox(height: 12),
        Container(
          height: 46,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            const SizedBox(width: 14),
            Icon(Icons.search_rounded, color: AppColors.hint, size: 21),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  _cat = null;
                  _sub = null;
                  _reload();
                },
                onChanged: (_) => setState(() {}),
                style: TextStyle(color: AppColors.inputFg, fontSize: 14.5),
                decoration: InputDecoration(
                  isCollapsed: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Robe longue, pyjama enfant, baskets…',
                  hintStyle: TextStyle(color: AppColors.hint, fontSize: 14),
                ),
              ),
            ),
            if (_search.text.isNotEmpty)
              IconButton(
                icon: Icon(Icons.close_rounded, color: AppColors.hint, size: 20),
                onPressed: () => _openCat(null),
              ),
          ]),
        ),
      ]),
    );
  }

  // ── Onglets d'univers (restent collés en haut) ──
  Widget _catTabs() {
    final names = <String?>[null, ..._cats.map((c) => c['name'] as String)];
    return Container(
      color: AppColors.bg,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        children: [
          for (final n in names)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _openCat(n),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: _cat == n && _search.text.trim().isEmpty ? _kShopGrad : null,
                    color: _cat == n && _search.text.trim().isEmpty ? null : AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: _cat == n && _search.text.trim().isEmpty ? Colors.transparent : AppColors.border),
                  ),
                  child: Text(n ?? 'Accueil',
                      style: TextStyle(
                          color: _cat == n && _search.text.trim().isEmpty ? Colors.white : AppColors.label,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Accueil ──
  List<Widget> _homeSlivers() => [
        const SliverToBoxAdapter(child: _PromoCarousel()),
        if (_cats.isNotEmpty) ...[
          SliverToBoxAdapter(child: _sectionTitle('Univers', null)),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 168,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  for (final c in _cats)
                    _UniverseCard(
                      name: c['name'] as String,
                      count: c['count'] as int,
                      image: c['image'] as String?,
                      onTap: () => _openCat(c['name'] as String),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (_best.isNotEmpty) ...[
          SliverToBoxAdapter(child: _sectionTitle('Meilleures ventes', 'Les favoris des clientes et clients')),
          SliverToBoxAdapter(child: _hList(_best)),
        ],
        if (_cheap.isNotEmpty) ...[
          SliverToBoxAdapter(child: _sectionTitle('Petits prix', 'Moins de 5 \$ — livraison comprise')),
          SliverToBoxAdapter(child: _hList(_cheap)),
        ],
      ];

  Widget _hList(List<dynamic> items) => SizedBox(
        height: 262,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) =>
              SizedBox(width: 150, child: _ProductTile(p: items[i] as Map<String, dynamic>)),
        ),
      );

  // ── Univers choisi ou recherche : sous-catégories + tri ──
  List<Widget> _listingHeader() {
    final c = _catData;
    final subs = ((c?['subs'] as List?) ?? []);
    final searching = _search.text.trim().isNotEmpty;
    return [
      if (searching)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Text('Résultats pour « ${_search.text.trim()} »',
                style: TextStyle(color: AppColors.label, fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
      if (!searching && subs.isNotEmpty)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 112,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              children: [
                _SubBubble(
                    label: 'Tout',
                    image: c?['image'] as String?,
                    selected: _sub == null,
                    onTap: () => _openCat(_cat)),
                for (final s in subs)
                  _SubBubble(
                    label: s['name'] as String,
                    image: s['image'] as String?,
                    selected: _sub == s['name'],
                    onTap: () => _openCat(_cat, sub: s['name'] as String),
                  ),
              ],
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 10, 0),
          child: Row(children: [
            Expanded(
              child: Text(
                  _sub ?? (searching ? '' : (c == null ? '' : '${c['name']} · ${c['count']} articles')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.sublabel, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            PopupMenuButton<String>(
              initialValue: _sort,
              color: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onSelected: (v) {
                _sort = v;
                _reload();
              },
              itemBuilder: (_) => [
                for (final e in _kShopSorts.entries)
                  PopupMenuItem(
                    value: e.key,
                    child: Row(children: [
                      Icon(e.key == _sort ? Icons.radio_button_checked : Icons.radio_button_off,
                          size: 18, color: e.key == _sort ? const Color(0xFF8B5CF6) : AppColors.hint),
                      const SizedBox(width: 10),
                      Text(e.value, style: TextStyle(color: AppColors.label)),
                    ]),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: [
                  Icon(Icons.swap_vert_rounded, size: 19, color: AppColors.label),
                  const SizedBox(width: 4),
                  Text(_kShopSorts[_sort]!,
                      style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w700, fontSize: 13)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ];
  }

  Widget _sectionTitle(String title, String? sub) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: AppColors.label, fontSize: 19, fontWeight: FontWeight.w800)),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub, style: TextStyle(color: AppColors.sublabel, fontSize: 12.5)),
          ],
        ]),
      );

  Widget _errorBox() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Icon(Icons.wifi_off_rounded, size: 42, color: AppColors.hint),
          const SizedBox(height: 10),
          Text(_err!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.sublabel)),
          const SizedBox(height: 12),
          TextButton(onPressed: _reload, child: const Text('Réessayer')),
        ]),
      );
}

class _PinnedBar extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  _PinnedBar({required this.height, required this.child});
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child;
  @override
  bool shouldRebuild(_PinnedBar old) => true;
}

// Bannières d'accueil : uniquement des promesses vraies (livraison et douane
// comprises, paiement avec le solde, nouveautés réelles du catalogue).
class _PromoCarousel extends StatefulWidget {
  const _PromoCarousel();
  @override
  State<_PromoCarousel> createState() => _PromoCarouselState();
}

class _PromoCarouselState extends State<_PromoCarousel> {
  final _pc = PageController(viewportFraction: 0.92);
  Timer? _t;
  int _i = 0;
  static const _slides = [
    (
      Icons.local_shipping_rounded,
      'Livré chez toi en Algérie',
      'Livraison et douane comprises dans le prix affiché.',
      [Color(0xFF00B4D8), Color(0xFF7C3AED)]
    ),
    (
      Icons.child_care_rounded,
      'Nouveau : Enfants & chaussures',
      'Bébé, fille, garçon — vêtements et chaussures.',
      [Color(0xFFF472B6), Color(0xFF8B5CF6)]
    ),
    (
      Icons.account_balance_wallet_rounded,
      'Paie avec ton solde Tchipa',
      'Ton agent le recharge en dinars, tu commandes en un geste.',
      [Color(0xFF10B981), Color(0xFF0EA5E9)]
    ),
  ];

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_pc.hasClients) return;
      _pc.animateToPage((_i + 1) % _slides.length,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const SizedBox(height: 8),
      SizedBox(
        height: 132,
        child: PageView.builder(
          controller: _pc,
          itemCount: _slides.length,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) {
            final s = _slides[i];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: s.$4, begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Stack(children: [
                  Positioned(
                    right: -18, bottom: -22,
                    child: Icon(s.$1, size: 130, color: Colors.white.withValues(alpha: 0.16)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 90, 18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(s.$2,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900, height: 1.15)),
                      const SizedBox(height: 6),
                      Text(s.$3,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 12.5, height: 1.3)),
                    ]),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < _slides.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: i == _i ? 18 : 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              gradient: i == _i ? _kShopGrad : null,
              color: i == _i ? null : AppColors.border,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ]),
    ]);
  }
}

class _UniverseCard extends StatelessWidget {
  final String name;
  final int count;
  final String? image;
  final VoidCallback onTap;
  const _UniverseCard({required this.name, required this.count, required this.image, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 132,
        margin: const EdgeInsets.only(right: 12),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: AppColors.card),
        child: Stack(fit: StackFit.expand, children: [
          _netImage(image),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xCC000000)],
                stops: [0.45, 1],
              ),
            ),
          ),
          Positioned(
            left: 12, right: 12, bottom: 12,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
              Text('$count articles',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _SubBubble extends StatelessWidget {
  final String label;
  final String? image;
  final bool selected;
  final VoidCallback onTap;
  const _SubBubble({required this.label, required this.image, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 78,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: selected ? _kShopGrad : null,
              color: selected ? null : AppColors.border,
            ),
            child: Container(
              width: 60, height: 60,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.bg),
              child: ClipOval(child: _netImage(image)),
            ),
          ),
          const SizedBox(height: 6),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: selected ? AppColors.label : AppColors.sublabel,
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Map<String, dynamic> p;
  const _ProductTile({required this.p});

  @override
  Widget build(BuildContext context) {
    final from = (p['priceFrom'] as num).toDouble();
    final to = ((p['priceTo'] as num?) ?? from).toDouble();
    final sold = (p['sold'] as num?) ?? 0;
    return GestureDetector(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => ProductScreen(productId: p['id'] as int))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 0.82,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(16)),
            child: Stack(fit: StackFit.expand, children: [
              _netImage(p['image'] as String?),
              if (sold >= 1000)
                Positioned(
                  left: 8, bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.local_fire_department_rounded, size: 12, color: Color(0xFFFFB020)),
                      const SizedBox(width: 3),
                      Text(_soldLabel(sold),
                          style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
          child: Text('${p['title']}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.label, fontSize: 13, fontWeight: FontWeight.w600, height: 1.25)),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            if (to > from + 0.01)
              Text('dès ', style: TextStyle(color: AppColors.hint, fontSize: 11)),
            Text(_usd(from),
                style: TextStyle(color: AppColors.label, fontSize: 16.5, fontWeight: FontWeight.w900)),
          ]),
        ),
      ]),
    );
  }
}

class _TileSkeleton extends StatelessWidget {
  const _TileSkeleton();
  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
        width: w, height: h,
        decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(6)));
    return Shimmer.fromColors(
      baseColor: AppColors.card,
      highlightColor: AppColors.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 0.82,
          child: Container(decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(16))),
        ),
        const SizedBox(height: 10),
        bar(double.infinity, 11),
        const SizedBox(height: 6),
        bar(90, 11),
        const SizedBox(height: 12),
        bar(60, 15),
      ]),
    );
  }
}

// ── Fiche produit : chaque variante (couleur × taille) a son prix ─────────
String _optLabel(String k) {
  final l = k.toLowerCase();
  if (l.contains('colo')) return 'Couleur';
  if (l.contains('height')) return 'Taille (hauteur de l\'enfant)';
  if (l.contains('size')) return 'Taille';
  if (l.contains('length')) return 'Longueur';
  return k;
}

class ProductScreen extends StatefulWidget {
  final int productId;
  const ProductScreen({super.key, required this.productId});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  Map<String, dynamic>? _p;
  String? _err;
  final Map<String, String> _sel = {};
  int _qty = 1, _img = 0;

  List<Map<String, dynamic>> get _variants =>
      ((_p?['variants'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  // Options built from the variants themselves, so every chip maps to a real variant.
  Map<String, List<String>> get _options {
    final o = <String, List<String>>{};
    for (final v in _variants) {
      (v['props'] as Map).forEach((k, val) {
        final list = o.putIfAbsent('$k', () => []);
        if (!list.contains('$val')) list.add('$val');
      });
    }
    return o;
  }

  Map<String, dynamic>? get _current {
    for (final v in _variants) {
      final props = v['props'] as Map;
      if (_sel.entries.every((e) => '${props[e.key]}' == e.value)) return v;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ShopApi.product(widget.productId);
      if (!mounted) return;
      setState(() => _p = d);
      if (_variants.isNotEmpty) {
        (_variants.first['props'] as Map).forEach((k, v) => _sel['$k'] = '$v');
        setState(() {});
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _err = e.message);
    }
  }

  void _pick(String key, String value) {
    setState(() {
      _sel[key] = value;
      if (_current == null) {
        // Keep the tapped value, move the other options to the first variant that has it.
        final v = _variants.firstWhere((v) => '${(v['props'] as Map)[key]}' == value, orElse: () => {});
        if (v.isNotEmpty) (v['props'] as Map).forEach((k, val) => _sel['$k'] = '$val');
      }
    });
  }

  bool _available(String key, String value) => _variants.any((v) {
        final props = v['props'] as Map;
        if ('${props[key]}' != value) return false;
        return _sel.entries.where((e) => e.key != key).every((e) => '${props[e.key]}' == e.value);
      });

  void _add() {
    final v = _current;
    if (v == null) return;
    Cart.add(CartLine(
      productId: widget.productId,
      title: '${_p!['title']}',
      image: _p!['image'] as String?,
      variant: '${v['name']}',
      props: Map<String, dynamic>.from(v['props'] as Map),
      unitUsd: (v['priceUsd'] as num).toDouble(),
      qty: _qty,
    ));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Ajouté au panier'),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
          label: 'Voir le panier',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CartScreen()))),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.label,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(p == null ? '' : '${p['sub'] ?? p['category'] ?? ''}',
            style: TextStyle(color: AppColors.label, fontSize: 16, fontWeight: FontWeight.w700)),
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: _CartButton())],
      ),
      body: p == null
          ? Center(
              child: _err != null
                  ? Text(_err!, style: TextStyle(color: AppColors.sublabel))
                  : const CircularProgressIndicator())
          : _body(p),
    );
  }

  Widget _body(Map<String, dynamic> p) {
    final images = ((p['images'] as List?) ?? []).cast<String>();
    final v = _current;
    final opts = _options;
    final hasSize = opts.keys.any((k) => k.toLowerCase().contains('size') || k.toLowerCase().contains('height'));
    final sold = (p['sold'] as num?) ?? 0;
    return Column(children: [
      Expanded(
        child: ListView(padding: EdgeInsets.zero, children: [
          AspectRatio(
            aspectRatio: 0.9,
            child: Stack(children: [
              PageView.builder(
                itemCount: max(1, images.length),
                onPageChanged: (i) => setState(() => _img = i),
                itemBuilder: (_, i) => _netImage(images.isEmpty ? null : images[i], thumb: false),
              ),
              if (images.length > 1)
                Positioned(
                  right: 14, bottom: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
                    child: Text('${_img + 1}/${images.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          ),
          if (images.length > 1)
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                itemCount: images.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => Container(
                  width: 54,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: i == _img ? const Color(0xFF8B5CF6) : Colors.transparent, width: 2),
                  ),
                  child: _netImage(images[i]),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                ShaderMask(
                  shaderCallback: (r) => _kShopGrad.createShader(r),
                  child: Text(v == null ? '—' : _usd(v['priceUsd'] as num),
                      style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900)),
                ),
                const Spacer(),
                if (sold > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      const Icon(Icons.local_fire_department_rounded, size: 16, color: Color(0xFFFFB020)),
                      const SizedBox(width: 3),
                      Text(_soldLabel(sold),
                          style: TextStyle(color: AppColors.sublabel, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ]),
                  ),
              ]),
              if (v == null)
                Text('Cette combinaison n\'est pas disponible',
                    style: TextStyle(color: AppColors.sublabel, fontSize: 12.5)),
              const SizedBox(height: 8),
              Text('${p['title']}',
                  style: TextStyle(color: AppColors.label, fontSize: 18, fontWeight: FontWeight.w700, height: 1.3)),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Row(children: [
                  _Perk(icon: Icons.local_shipping_rounded, text: 'Livré en\nAlgérie'),
                  _Perk(icon: Icons.verified_user_rounded, text: 'Douane\ncomprise'),
                  _Perk(icon: Icons.account_balance_wallet_rounded, text: 'Payé avec\nton solde'),
                ]),
              ),
              for (final e in opts.entries) ...[
                const SizedBox(height: 20),
                Row(children: [
                  Text(_optLabel(e.key),
                      style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w800, fontSize: 15)),
                  if (_sel[e.key] != null) ...[
                    Text('  ·  ', style: TextStyle(color: AppColors.hint)),
                    Expanded(
                      child: Text(_sel[e.key]!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.sublabel, fontSize: 13.5)),
                    ),
                  ],
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final val in e.value)
                    GestureDetector(
                      onTap: () => _pick(e.key, val),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          color: _sel[e.key] == val
                              ? const Color(0xFF8B5CF6).withValues(alpha: 0.12)
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            width: _sel[e.key] == val ? 1.6 : 1,
                            color: _sel[e.key] == val ? const Color(0xFF8B5CF6) : AppColors.border,
                          ),
                        ),
                        child: Text(val,
                            style: TextStyle(
                                color: _available(e.key, val) ? AppColors.label : AppColors.hint,
                                decoration: _available(e.key, val) ? null : TextDecoration.lineThrough,
                                fontWeight: _sel[e.key] == val ? FontWeight.w800 : FontWeight.w600)),
                      ),
                    ),
                ]),
              ],
              if (hasSize)
                Container(
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF79009).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.straighten_rounded, size: 18, color: Color(0xFFF79009)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'Tailles chinoises : elles taillent petit. Prends 1 à 2 tailles au-dessus de ta taille habituelle.',
                          style: TextStyle(color: AppColors.label, fontSize: 13, height: 1.35)),
                    ),
                  ]),
                ),
              const SizedBox(height: 18),
              Row(children: [
                Text('Quantité', style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w800, fontSize: 15)),
                const Spacer(),
                Container(
                  decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border)),
                  child: Row(children: [
                    IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                        icon: Icon(Icons.remove_rounded, color: AppColors.label)),
                    Text('$_qty',
                        style: TextStyle(color: AppColors.label, fontSize: 16, fontWeight: FontWeight.w800)),
                    IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: _qty < 10 ? () => setState(() => _qty++) : null,
                        icon: Icon(Icons.add_rounded, color: AppColors.label)),
                  ]),
                ),
              ]),
              const SizedBox(height: 28),
            ]),
          ),
        ]),
      ),
      Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(children: [
              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Total', style: TextStyle(color: AppColors.hint, fontSize: 11.5)),
                Text(v == null ? '—' : _usd((v['priceUsd'] as num) * _qty),
                    style: TextStyle(color: AppColors.label, fontSize: 19, fontWeight: FontWeight.w900)),
              ]),
              const SizedBox(width: 16),
              Expanded(
                child: _GradButton(
                    label: v == null ? 'Indisponible' : 'Ajouter au panier', onTap: v == null ? null : _add),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _Perk extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Perk({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Icon(icon, size: 22, color: const Color(0xFF8B5CF6)),
          const SizedBox(height: 6),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.sublabel, fontSize: 11.5, height: 1.25, fontWeight: FontWeight.w600)),
        ]),
      );
}

// ── Panier + paiement avec le solde ──────────────────────────────────────
const List<String> kWilayas = [
  'Adrar', 'Chlef', 'Laghouat', 'Oum El Bouaghi', 'Batna', 'Béjaïa', 'Biskra', 'Béchar', 'Blida', 'Bouira',
  'Tamanrasset', 'Tébessa', 'Tlemcen', 'Tiaret', 'Tizi Ouzou', 'Alger', 'Djelfa', 'Jijel', 'Sétif', 'Saïda',
  'Skikda', 'Sidi Bel Abbès', 'Annaba', 'Guelma', 'Constantine', 'Médéa', 'Mostaganem', "M'Sila", 'Mascara',
  'Ouargla', 'Oran', 'El Bayadh', 'Illizi', 'Bordj Bou Arréridj', 'Boumerdès', 'El Tarf', 'Tindouf',
  'Tissemsilt', 'El Oued', 'Khenchela', 'Souk Ahras', 'Tipaza', 'Mila', 'Aïn Defla', 'Naâma',
  'Aïn Témouchent', 'Ghardaïa', 'Relizane', 'Timimoun', 'Bordj Badji Mokhtar', 'Ouled Djellal', 'Béni Abbès',
  'In Salah', 'In Guezzam', 'Touggourt', 'Djanet', "El M'Ghair", 'El Meniaa',
];

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});
  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _name = TextEditingController(text: UserProfile.name);
  final _phone = TextEditingController(text: UserProfile.phone);
  final _commune = TextEditingController();
  final _address = TextEditingController();
  String? _wilaya;
  double? _balance;
  bool _busy = false;
  String _idem = _idemKey(); // one key per checkout attempt: a double tap pays once

  @override
  void initState() {
    super.initState();
    _refreshBalance();
  }

  Future<void> _refreshBalance() async {
    if (!ShopApi.loggedIn) return;
    try {
      final d = await ShopApi.me();
      if (mounted) setState(() => _balance = (d['balanceUsd'] as num).toDouble());
    } catch (_) {}
  }

  bool get _formOk =>
      _name.text.trim().isNotEmpty && _phone.text.trim().length >= 9 && _wilaya != null;

  Future<void> _pay() async {
    if (!ShopApi.loggedIn) {
      if (!await showWalletLogin(context)) return;
      await _refreshBalance();
    }
    setState(() => _busy = true);
    try {
      final d = await ShopApi.placeOrder(Cart.lines.value, {
        'fullName': _name.text.trim(),
        'phone': _phone.text.trim(),
        'wilaya': _wilaya!,
        'commune': _commune.text.trim(),
        'address': _address.text.trim(),
      }, _idem);
      Cart.clear();
      _idem = _idemKey();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Commande #${d['orderId']} payée',
              style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w800)),
          content: Text(
              'Nous achetons tes articles chez le fournisseur. Suis ta commande dans « Mon solde → Mes commandes ».\n\n'
              'Solde restant : ${_usd(d['balanceUsd'] as num)}',
              style: TextStyle(color: AppColors.sublabel)),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const OrdersScreen()));
      }
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.status == 402) {
        final missing = (e.body['totalUsd'] as num) - (e.body['balanceUsd'] as num);
        _toast(context, 'Solde insuffisant : il te manque ${_usd(missing)}. Paie ton agent en dinars pour recharger.',
            error: true);
        _refreshBalance();
      } else if (e.status == 401) {
        _toast(context, 'Session expirée, reconnecte-toi.', error: true);
      } else {
        _toast(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
          backgroundColor: AppColors.bg, foregroundColor: AppColors.label, elevation: 0,
          title: const Text('Mon panier')),
      body: ValueListenableBuilder<List<CartLine>>(
        valueListenable: Cart.lines,
        builder: (_, lines, __) {
          if (lines.isEmpty) {
            return Center(
                child: Text('Ton panier est vide', style: TextStyle(color: AppColors.sublabel, fontSize: 16)));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            for (final l in lines)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(10),
                      child: SizedBox(width: 70, height: 70, child: _netImage(l.image))),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w600)),
                    Text(l.variantLabel, style: TextStyle(color: AppColors.sublabel, fontSize: 12)),
                    Text(_usd(l.unitUsd * l.qty),
                        style: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.w800)),
                  ])),
                  Column(children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(visualDensity: VisualDensity.compact,
                          onPressed: () => Cart.setQty(l, l.qty - 1),
                          icon: Icon(Icons.remove, color: AppColors.label, size: 18)),
                      Text('${l.qty}', style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w700)),
                      IconButton(visualDensity: VisualDensity.compact,
                          onPressed: () => Cart.setQty(l, l.qty + 1),
                          icon: Icon(Icons.add, color: AppColors.label, size: 18)),
                    ]),
                  ]),
                ]),
              ),
            const SizedBox(height: 8),
            Text('Livraison', style: TextStyle(color: AppColors.label, fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            TextField(controller: _name, onChanged: (_) => setState(() {}),
                style: TextStyle(color: AppColors.inputFg), decoration: _field('Nom et prénom')),
            const SizedBox(height: 10),
            TextField(controller: _phone, keyboardType: TextInputType.phone, onChanged: (_) => setState(() {}),
                style: TextStyle(color: AppColors.inputFg), decoration: _field('Téléphone pour le livreur')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              // `value`, not `initialValue`: CI's Flutter predates initialValue.
              // ignore: deprecated_member_use
              value: _wilaya,
              isExpanded: true,
              dropdownColor: AppColors.surface,
              style: TextStyle(color: AppColors.inputFg),
              decoration: _field('Wilaya'),
              items: [
                for (var i = 0; i < kWilayas.length; i++)
                  DropdownMenuItem(value: kWilayas[i], child: Text('${i + 1} — ${kWilayas[i]}')),
              ],
              onChanged: (v) => setState(() => _wilaya = v),
            ),
            const SizedBox(height: 10),
            TextField(controller: _commune, style: TextStyle(color: AppColors.inputFg), decoration: _field('Commune')),
            const SizedBox(height: 10),
            TextField(controller: _address, style: TextStyle(color: AppColors.inputFg),
                decoration: _field('Adresse (rue, quartier, point de repère)')),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
              child: Column(children: [
                Row(children: [
                  Text('Total', style: TextStyle(color: AppColors.label, fontSize: 16, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(_usd(Cart.total),
                      style: TextStyle(color: AppColors.label, fontSize: 20, fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Text('Mon solde', style: TextStyle(color: AppColors.sublabel)),
                  const Spacer(),
                  Text(_balance == null ? (ShopApi.loggedIn ? '…' : 'non connecté') : _usd(_balance!),
                      style: TextStyle(
                          color: _balance != null && _balance! < Cart.total
                              ? const Color(0xFFF97066)
                              : AppColors.sublabel,
                          fontWeight: FontWeight.w600)),
                ]),
              ]),
            ),
            const SizedBox(height: 16),
            _GradButton(
                label: 'Payer ${_usd(Cart.total)} avec mon solde', busy: _busy, onTap: _formOk ? _pay : null),
            const SizedBox(height: 8),
            Text('Livraison en Algérie et douane comprises. Délai indicatif : 2 à 4 semaines.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.hint, fontSize: 12)),
            const SizedBox(height: 30),
          ]);
        },
      ),
    );
  }
}

// ── Onglet Solde ─────────────────────────────────────────────────────────
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _me;
  String? _err;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!ShopApi.loggedIn) {
      setState(() => _me = null);
      return;
    }
    setState(() { _loading = true; _err = null; });
    try {
      final d = await ShopApi.me();
      if (mounted) setState(() => _me = d);
    } on ApiError catch (e) {
      if (mounted) setState(() => _err = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _kinds = {
    'agent_credit': ('Recharge par ton agent', Icons.south_west_rounded, Color(0xFF12B76A)),
    'purchase': ('Achat boutique', Icons.shopping_bag_outlined, Color(0xFFF97066)),
    'refund': ('Remboursement', Icons.undo_rounded, Color(0xFF12B76A)),
    'adjust': ('Correction', Icons.tune_rounded, Color(0xFF8B5CF6)),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: !ShopApi.loggedIn
            ? _loginPrompt()
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 120), children: [
                  Text('Mon solde',
                      style: TextStyle(color: AppColors.label, fontSize: 28, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(gradient: _kShopGrad, borderRadius: BorderRadius.circular(22)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('SOLDE DISPONIBLE',
                          style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1.2,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(_me == null ? (_loading ? '…' : '—') : _usd(_me!['balanceUsd'] as num),
                          style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text('${_me?['phone'] ?? ''}', style: const TextStyle(color: Colors.white70)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                    child: Text(
                        'Pour recharger : paie ton agent Tchipa en dinars (BaridiMob). Il crédite ton solde en dollars, '
                        'et tu achètes dans la boutique.',
                        style: TextStyle(color: AppColors.sublabel, fontSize: 13.5)),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const OrdersScreen())),
                        icon: const Icon(Icons.local_shipping_outlined),
                        label: const Text('Mes commandes'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse(kAgentTelegram), mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.support_agent_rounded),
                        label: const Text('Mon agent'),
                      ),
                    ),
                  ]),
                  if (_err != null)
                    Padding(padding: const EdgeInsets.only(top: 12),
                        child: Text(_err!, style: const TextStyle(color: Color(0xFFF97066)))),
                  const SizedBox(height: 20),
                  Text('Historique',
                      style: TextStyle(color: AppColors.label, fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if ((_me?['history'] as List? ?? []).isEmpty)
                    Text('Aucune opération pour le moment.', style: TextStyle(color: AppColors.sublabel)),
                  for (final h in (_me?['history'] as List? ?? [])) _historyRow(h as Map<String, dynamic>),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () async {
                      await ShopApi.logout();
                      if (mounted) setState(() => _me = null);
                    },
                    child: Text('Se déconnecter', style: TextStyle(color: AppColors.hint)),
                  ),
                ]),
              ),
      ),
    );
  }

  Widget _historyRow(Map<String, dynamic> h) {
    final k = _kinds[h['kind']] ?? ('Opération', Icons.swap_horiz_rounded, const Color(0xFF8B5CF6));
    final amt = (h['amountUsd'] as num).toDouble();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        CircleAvatar(radius: 18, backgroundColor: k.$3.withValues(alpha: 0.15), child: Icon(k.$2, color: k.$3, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k.$1, style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w600)),
          Text('${h['ref'] ?? ''} ${(h['at'] ?? '').toString().replaceFirst('T', ' ')}'.trim(),
              style: TextStyle(color: AppColors.hint, fontSize: 12)),
        ])),
        Text('${amt >= 0 ? '+' : ''}${_usd(amt)}',
            style: TextStyle(color: amt >= 0 ? const Color(0xFF12B76A) : AppColors.label,
                fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _loginPrompt() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Icon(Icons.account_balance_wallet_rounded, size: 64, color: AppColors.hint),
          const SizedBox(height: 16),
          Text('Mon solde Tchipa', textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.label, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('Ton argent en dollars pour acheter dans la boutique. Ton agent le recharge quand tu le paies en dinars.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.sublabel)),
          const SizedBox(height: 24),
          _GradButton(
              label: 'Me connecter avec mon PIN',
              onTap: () async {
                if (await showWalletLogin(context)) _load();
              }),
        ]),
      );
}

// ── Mes commandes ────────────────────────────────────────────────────────
const Map<String, (String, Color)> kOrderStatus = {
  'payee': ('Payée — en préparation', Color(0xFF00D4FF)),
  'achetee': ('Achetée chez le fournisseur', Color(0xFF8B5CF6)),
  'entrepot': ('À l\'entrepôt en Chine', Color(0xFF8B5CF6)),
  'expediee': ('Expédiée vers l\'Algérie', Color(0xFFF79009)),
  'livree': ('Livrée', Color(0xFF12B76A)),
  'annulee': ('Annulée — remboursée', Color(0xFFF97066)),
};

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<dynamic>? _orders;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await ShopApi.myOrders();
      if (mounted) setState(() => _orders = o);
    } on ApiError catch (e) {
      if (mounted) setState(() => _err = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
          backgroundColor: AppColors.bg, foregroundColor: AppColors.label, elevation: 0,
          title: const Text('Mes commandes')),
      body: _orders == null
          ? Center(child: _err != null
              ? Text(_err!, style: TextStyle(color: AppColors.sublabel))
              : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _orders!.isEmpty
                  ? ListView(children: [
                      const SizedBox(height: 120),
                      Center(child: Text('Pas encore de commande', style: TextStyle(color: AppColors.sublabel))),
                    ])
                  : ListView(padding: const EdgeInsets.all(16), children: [
                      for (final o in _orders!) _order(o as Map<String, dynamic>),
                    ]),
            ),
    );
  }

  Widget _order(Map<String, dynamic> o) {
    final st = kOrderStatus[o['status']] ?? ('${o['status']}', AppColors.hint);
    final items = (o['items'] as List?) ?? [];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Commande #${o['id']}', style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text(_usd(o['totalUsd'] as num), style: TextStyle(color: AppColors.label, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: st.$2.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
          child: Text(st.$1, style: TextStyle(color: st.$2, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ),
        if (o['tracking'] != null)
          Padding(padding: const EdgeInsets.only(top: 6),
              child: Text('Suivi : ${o['tracking']}', style: TextStyle(color: AppColors.sublabel))),
        const SizedBox(height: 10),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              ClipRRect(borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 44, height: 44, child: _netImage(it['image'] as String?))),
              const SizedBox(width: 10),
              Expanded(child: Text('${it['qty']} × ${it['title']}', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.sublabel, fontSize: 13))),
            ]),
          ),
      ]),
    );
  }
}

// ── Espace agent : créditer le solde d'un client ─────────────────────────
// Replaces the shared PIN 1234 for money operations: each agent has a personal
// code (created by Tarik via POST /admin/agents). Agents are prepaid: they pay
// Tarik first, Tarik loads their provision, and each client credit is taken
// from it — the server refuses a credit larger than the remaining provision.
class AgentWalletScreen extends StatefulWidget {
  const AgentWalletScreen({super.key});
  @override
  State<AgentWalletScreen> createState() => _AgentWalletScreenState();
}

class _AgentWalletScreenState extends State<AgentWalletScreen> {
  final _code = TextEditingController();
  final _phone = TextEditingController();
  final _amount = TextEditingController();
  final _dzd = TextEditingController();
  final _ref = TextEditingController();
  Map<String, dynamic>? _me;
  List<dynamic> _credits = [];
  bool _busy = false;
  String? _err;
  String _idem = _idemKey();

  @override
  void initState() {
    super.initState();
    if (ShopApi.agentToken != null) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final me = await ShopApi.agentMe();
      final c = await ShopApi.agentCredits();
      if (mounted) setState(() { _me = me; _credits = c; _err = null; });
    } on ApiError catch (e) {
      if (e.status == 401) {
        await ShopApi.setAgentToken(null);
        if (mounted) setState(() { _me = null; _err = 'Code agent refusé ou désactivé.'; });
      } else if (mounted) {
        setState(() => _err = e.message);
      }
    }
  }

  Future<void> _saveCode() async {
    final t = _code.text.trim();
    setState(() { _busy = true; _err = null; });
    try {
      await ShopApi.agentMe(t);
      await ShopApi.setAgentToken(t);
      _code.clear();
      await _refresh();
    } on ApiError catch (e) {
      setState(() => _err = e.status == 401 ? 'Code agent invalide.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _credit() async {
    final amount = _amount.text.trim().replaceAll(',', '.');
    final phone = _phone.text.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Confirmer le crédit', style: TextStyle(color: AppColors.label)),
        content: Text('Créditer $amount \$ sur le solde du $phone ?\n\nVérifie bien le numéro : '
            'l\'argent ira sur ce compte.', style: TextStyle(color: AppColors.sublabel)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créditer')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() { _busy = true; _err = null; });
    try {
      await ShopApi.agentCredit(
          phone: phone,
          amount: amount,
          dzd: int.tryParse(_dzd.text.replaceAll(RegExp(r'\s'), '')),
          ref: _ref.text.trim(),
          idem: _idem);
      _idem = _idemKey();
      _phone.clear(); _amount.clear(); _dzd.clear(); _ref.clear();
      if (mounted) _toast(context, 'Crédit de $amount \$ envoyé sur $phone');
      await _refresh();
    } on ApiError catch (e) {
      // Same key is kept: retrying after a network error credits once.
      if (mounted) setState(() => _err = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg, foregroundColor: AppColors.label, elevation: 0,
        title: const Text('Espace agent'),
        actions: [
          if (ShopApi.agentToken != null)
            IconButton(
              tooltip: 'Oublier mon code',
              onPressed: () async {
                await ShopApi.setAgentToken(null);
                setState(() => _me = null);
              },
              icon: const Icon(Icons.logout_rounded),
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (ShopApi.agentToken == null) ...[
          Text('Entre ton code agent personnel (donné par Tchipa).',
              style: TextStyle(color: AppColors.sublabel)),
          const SizedBox(height: 12),
          TextField(controller: _code, style: TextStyle(color: AppColors.inputFg),
              decoration: _field('Code agent', hint: 'agt_…', icon: Icons.key_rounded)),
          const SizedBox(height: 12),
          _GradButton(label: 'Valider', busy: _busy, onTap: _saveCode),
        ] else ...[
          if (_me != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_me!['name']}', style: TextStyle(color: AppColors.label, fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('Ma provision : ${_usd(_me!['availableUsd'] as num)}',
                    style: const TextStyle(color: Color(0xFF12B76A), fontSize: 16, fontWeight: FontWeight.w700)),
                Text('Chaque crédit client est pris sur ta provision. Pour la recharger, paie Tchipa.',
                    style: TextStyle(color: AppColors.sublabel, fontSize: 12.5)),
              ]),
            ),
          const SizedBox(height: 18),
          Text('Créditer un client', style: TextStyle(color: AppColors.label, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          TextField(controller: _phone, keyboardType: TextInputType.phone, onChanged: (_) => setState(() {}),
              style: TextStyle(color: AppColors.inputFg), decoration: _field('Téléphone du client', icon: Icons.phone_rounded)),
          const SizedBox(height: 10),
          TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: AppColors.inputFg), decoration: _field('Montant en dollars', hint: '25.00', icon: Icons.attach_money_rounded)),
          const SizedBox(height: 10),
          TextField(controller: _dzd, keyboardType: TextInputType.number,
              style: TextStyle(color: AppColors.inputFg), decoration: _field('Dinars reçus (facultatif)', icon: Icons.payments_outlined)),
          const SizedBox(height: 10),
          TextField(controller: _ref,
              style: TextStyle(color: AppColors.inputFg), decoration: _field('Référence BaridiMob (facultatif)', icon: Icons.receipt_outlined)),
          if (_err != null)
            Padding(padding: const EdgeInsets.only(top: 10),
                child: Text(_err!, style: const TextStyle(color: Color(0xFFF97066)))),
          const SizedBox(height: 14),
          _GradButton(
              label: 'Créditer',
              busy: _busy,
              onTap: _phone.text.trim().length >= 9 && _amount.text.trim().isNotEmpty ? _credit : null),
          const SizedBox(height: 22),
          Text('Mes derniers crédits', style: TextStyle(color: AppColors.label, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_credits.isEmpty) Text('Aucun crédit pour le moment.', style: TextStyle(color: AppColors.sublabel)),
          for (final c in _credits)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${c['phone']}', style: TextStyle(color: AppColors.label)),
              subtitle: Text('${c['at']}${c['ref'] != null ? ' · ${c['ref']}' : ''}',
                  style: TextStyle(color: AppColors.hint, fontSize: 12)),
              trailing: Text('+${_usd(c['amountUsd'] as num)}',
                  style: const TextStyle(color: Color(0xFF12B76A), fontWeight: FontWeight.w800)),
            ),
        ],
        if (ShopApi.agentToken == null && _err != null)
          Padding(padding: const EdgeInsets.only(top: 10),
              child: Text(_err!, style: const TextStyle(color: Color(0xFFF97066)))),
      ]),
    );
  }
}
