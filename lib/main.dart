import 'dart:math';
import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ============================================
// CONFIGURATION
// ============================================
const String kVpsBase       = 'https://api.tchipa.co.uk';
const double kExchangeRate  = 242.0;
const double kActivationFee = 7.0;
const String kAgentTelegram = 'https://t.me/c/3983752002/1';

// ============================================
// VCC CARD MODEL
// ============================================
class VccCard {
  final String? cardId;
  final String? cardNumber;
  final String? expiry;
  final String? cvv;
  final String? holderName;
  final double balance;
  final bool isActivated;
  final String? redeemId;
  final String? redeemLink;

  const VccCard({
    this.cardId,
    this.cardNumber,
    this.expiry,
    this.cvv,
    this.holderName,
    this.balance = 0.0,
    this.isActivated = false,
    this.redeemId,
    this.redeemLink,
  });

  bool get hasCard =>
      (cardNumber != null && cardNumber!.isNotEmpty) || redeemLink != null;

  String get maskedNumber {
    if (cardNumber == null || cardNumber!.isEmpty) return '•••• •••• •••• ••••';
    final n = cardNumber!.replaceAll(RegExp(r'[\s\-]'), '');
    if (n.length != 16) return cardNumber!;
    return '•••• •••• •••• ${n.substring(12)}';
  }

  String get formattedNumber {
    if (cardNumber == null || cardNumber!.isEmpty) return '•••• •••• •••• ••••';
    final n = cardNumber!.replaceAll(RegExp(r'[\s\-]'), '');
    if (n.length != 16) return cardNumber!;
    return '${n.substring(0, 4)} ${n.substring(4, 8)} '
        '${n.substring(8, 12)} ${n.substring(12)}';
  }

  Map<String, dynamic> toJson() => {
        'cardId': cardId,
        'cardNumber': cardNumber,
        'expiry': expiry,
        'cvv': cvv,
        'holderName': holderName,
        'balance': balance,
        'isActivated': isActivated,
        'redeemId': redeemId,
        'redeemLink': redeemLink,
      };

  factory VccCard.fromJson(Map<String, dynamic> j) => VccCard(
        cardId: j['cardId']?.toString() ??
            j['card_id']?.toString() ??
            j['id']?.toString(),
        cardNumber: j['cardNumber']?.toString() ??
            j['card_number']?.toString() ??
            j['number']?.toString(),
        expiry: j['expiry']?.toString() ??
            j['expiration']?.toString() ??
            j['exp']?.toString(),
        cvv: j['cvv']?.toString() ?? j['cvc']?.toString(),
        holderName: j['holderName']?.toString() ??
            j['holder_name']?.toString() ??
            j['name']?.toString(),
        balance: (j['balance'] as num?)?.toDouble() ?? 0.0,
        isActivated: j['isActivated'] as bool? ??
            j['is_activated'] as bool? ??
            false,
        redeemId: j['redeemId']?.toString(),
        redeemLink: j['redeemLink']?.toString(),
      );

  VccCard copyWith({
    String? cardId,
    String? cardNumber,
    String? expiry,
    String? cvv,
    String? holderName,
    double? balance,
    bool? isActivated,
    String? redeemId,
    String? redeemLink,
  }) =>
      VccCard(
        cardId: cardId ?? this.cardId,
        cardNumber: cardNumber ?? this.cardNumber,
        expiry: expiry ?? this.expiry,
        cvv: cvv ?? this.cvv,
        holderName: holderName ?? this.holderName,
        balance: balance ?? this.balance,
        isActivated: isActivated ?? this.isActivated,
        redeemId: redeemId ?? this.redeemId,
        redeemLink: redeemLink ?? this.redeemLink,
      );

  static Future<VccCard?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('vcc_card');
    if (raw == null) return null;
    try {
      return VccCard.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vcc_card', jsonEncode(toJson()));
  }

  static Future<void> remove() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('vcc_card');
  }
}

// ============================================
// VCC ORDER (pending crypto payment)
// ============================================
class VccOrder {
  // For self-serve: the redeem_id returned by PayGate, used to poll
  // /paygate/check-status. For agent flow: empty — the agent app must use
  // agentOrderToken instead (backend deliberately hides the redeem_id from
  // agents).
  final String redeemId;
  final String cryptoAddress;
  final String amountUsdt;
  final String? qrCodeBase64;
  final double cardValue;
  final String cardType;
  // Agent-flow only: opaque UUID the agent uses to poll order status without
  // ever learning the underlying redeem_id.
  final String? agentOrderToken;
  // Agent-flow only: 4-digit secret returned by the backend on creation.
  // Agent must relay it out-of-band (Telegram, SMS, voice) so the user's
  // app can unlock the redeem link via /cards/claim-with-code.
  final String? claimCode;

  const VccOrder({
    required this.redeemId,
    required this.cryptoAddress,
    required this.amountUsdt,
    required this.cardValue,
    required this.cardType,
    this.qrCodeBase64,
    this.agentOrderToken,
    this.claimCode,
  });

  factory VccOrder.fromJson(Map<String, dynamic> j) => VccOrder(
        redeemId:        j['redeemId']?.toString() ?? '',
        cryptoAddress:   j['cryptoAddress']?.toString() ?? '',
        amountUsdt:      j['amountUsdt']?.toString() ?? '0',
        cardValue:       (j['cardValue'] as num?)?.toDouble() ?? 0.0,
        cardType:        j['cardType']?.toString() ?? 'mastercard',
        qrCodeBase64:    j['qrCode']?.toString(),
        agentOrderToken: j['agentOrderToken']?.toString(),
        claimCode:       j['claimCode']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'redeemId':        redeemId,
        'cryptoAddress':   cryptoAddress,
        'amountUsdt':      amountUsdt,
        'cardValue':       cardValue,
        'cardType':        cardType,
        'qrCode':          qrCodeBase64,
        'agentOrderToken': agentOrderToken,
        'claimCode':       claimCode,
      };

  // Pending order persistence — one slot per flow ('activation'|'recharge')
  // to prevent the duplicate-redeem_id bug: opening the sheet again restores
  // the existing order instead of creating a new PayGate redeem_id that the
  // app would then poll while the actual payment lives under the old one.
  static const _kPendingPrefix    = 'pending_vcc_';
  static const _kPendingExpiryHrs = 24;

  static String _key(String flow) => '$_kPendingPrefix$flow';

  Future<void> savePending(String flow) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(flow), jsonEncode({
      ...toJson(),
      'createdAt': DateTime.now().toIso8601String(),
    }));
  }

  static Future<VccOrder?> loadPending(String flow) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(flow));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final created = DateTime.tryParse(j['createdAt']?.toString() ?? '');
      if (created != null &&
          DateTime.now().difference(created).inHours > _kPendingExpiryHrs) {
        await clearPending(flow);
        return null;
      }
      return VccOrder.fromJson(j);
    } catch (_) {
      await clearPending(flow);
      return null;
    }
  }

  static Future<void> clearPending(String flow) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(flow));
  }
}

// ============================================
// TRANSACTION MODEL
// ============================================
class VccTx {
  final String type;
  final double amount;
  final String label;
  final DateTime date;
  final bool isDebit;

  const VccTx({
    required this.type,
    required this.amount,
    required this.label,
    required this.date,
    this.isDebit = false,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'amount': amount,
        'label': label,
        'date': date.toIso8601String(),
        'isDebit': isDebit,
      };

  factory VccTx.fromJson(Map<String, dynamic> j) => VccTx(
        type: j['type'] as String? ?? 'payment',
        amount: (j['amount'] as num?)?.toDouble() ?? 0.0,
        label: j['label'] as String? ?? '',
        date: DateTime.tryParse(j['date'] as String? ?? '') ??
            DateTime.now(),
        isDebit: j['isDebit'] as bool? ?? false,
      );

  static Future<List<VccTx>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('vcc_txs') ?? [])
        .map((s) {
          try {
            return VccTx.fromJson(
                jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<VccTx>()
        .toList();
  }

  static Future<void> add(VccTx tx) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('vcc_txs') ?? [];
    list.insert(0, jsonEncode(tx.toJson()));
    await prefs.setStringList('vcc_txs', list.take(100).toList());
  }
}

// ============================================
// USER PROFILE
// ============================================
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
      final status = await PayGateService.authPinStatus(phone);
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
      await PayGateService.authSetupPin(phone: phone, email: email, pin: pin);
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
            await PayGateService.authChangePin(phone: phone, oldPin: oldPin, newPin: newPin);
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
            final s = await PayGateService.authPinStatus(phone);
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
            final s = await PayGateService.authPinStatus(phone);
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
// PAYGATE SERVICE
// ============================================
class PayGateService {
  static Future<VccOrder> createVccOrder({
    required double amount,
    String cardType = 'mastercard',
    String? holderName,
    String? phone,
    String? flow, // 'activation' | 'recharge' — only meaningful when phone is set (agent flow)
    String? source, // 'self' (user pays own card) | 'agent' (agent issues for a client)
    String? clientEmail, // agent flow: must match the client's verified email
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kVpsBase/paygate/create-vcc'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'amount': amount,
            'cardType': cardType,
            'holderName': holderName,
            'phone': phone,
            if (flow != null) 'flow': flow,
            if (source != null) 'source': source,
            if (clientEmail != null) 'clientEmail': clientEmail,
          }),
        )
        .timeout(const Duration(seconds: 35));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return VccOrder.fromJson(body);
    }
    // Backend uses `message` for human-readable details (CLIENT_NO_PIN etc.)
    final err = body['message']?.toString() ?? body['error']?.toString() ?? 'Erreur PayGate (${resp.statusCode})';
    throw Exception(err);
  }

  static Future<Map<String, dynamic>> checkVccStatus(String redeemId) async {
    final resp = await http
        .get(Uri.parse(
            '$kVpsBase/paygate/check-status?redeem_id=${Uri.encodeComponent(redeemId)}'))
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) return body;
    throw Exception(body['error'] ?? 'Erreur statut (${resp.statusCode})');
  }

  // Agent-side: coarse state only, NO redeem_link (anti-card-theft). Uses
  // an opaque token rather than redeem_id — the agent never learns the
  // underlying redeem_id, so they can't bypass the gate by hitting
  // /paygate/check-status directly.
  // Returns: { state: 'pending'|'paid'|'completed', isPaid, isReady, delivered }
  static Future<Map<String, dynamic>> checkAgentOrderStatus(String token) async {
    final resp = await http
        .get(Uri.parse(
            '$kVpsBase/agent/order-status?token=${Uri.encodeComponent(token)}'))
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) return body;
    throw Exception(body['error'] ?? 'Erreur statut (${resp.statusCode})');
  }

  // Client-side: discover any cards issued for this phone by an agent.
  static Future<List<Map<String, dynamic>>> fetchCardsForPhone(String phone) async {
    final resp = await http
        .get(Uri.parse('$kVpsBase/cards/for-phone/${Uri.encodeComponent(phone)}'))
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('fetchCardsForPhone failed (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (body['cards'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return list;
  }

  // Client-side: unlock the redeem link for a code-gated agent card.
  // Returns (redeemLink, redeemId) on success — the redeemId is needed so the
  // client can later mark the card as delivered. Throws on bad code / lockout
  // / not-ready with a human-readable French error from the backend.
  static Future<({String redeemLink, String redeemId})> claimCardWithCode({
    required String phone,
    required String cardToken,
    required String code,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kVpsBase/cards/claim-with-code'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phone': phone,
            'card_token': cardToken,
            'code': code,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) {
      final link = body['redeemLink']?.toString();
      final rid  = body['redeemId']?.toString();
      if (link == null || link.isEmpty || rid == null || rid.isEmpty) {
        throw Exception('Lien de carte indisponible');
      }
      return (redeemLink: link, redeemId: rid);
    }
    throw Exception(body['error']?.toString() ?? 'Erreur (${resp.statusCode})');
  }

  static Future<void> markCardDelivered(String redeemId) async {
    try {
      await http
          .post(Uri.parse('$kVpsBase/cards/mark-delivered'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'redeem_id': redeemId}))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Non-fatal: a missed mark just means the client may re-fetch the same
      // card on the next poll. Local dedup by redeemId catches it.
    }
  }

  static Future<double> fetchBalance(String cardId) async => 0.0;

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

  // Client-side: unlock a PIN-gated card. PIN is the client's own secret,
  // never seen by the agent.
  static Future<({String redeemLink, String redeemId})> claimCardWithPin({
    required String phone,
    required String cardToken,
    required String pin,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kVpsBase/cards/claim-with-pin'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'phone': phone, 'card_token': cardToken, 'pin': pin}),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) {
      final link = body['redeemLink']?.toString();
      final rid  = body['redeemId']?.toString();
      if (link == null || link.isEmpty || rid == null || rid.isEmpty) {
        throw Exception('Lien de carte indisponible');
      }
      return (redeemLink: link, redeemId: rid);
    }
    throw Exception(body['error']?.toString() ?? 'Erreur (${resp.statusCode})');
  }
}

// ============================================
// AGENT PIN (configurable, persisted)
// ============================================
class AgentPin {
  static const _kKey = 'agent_pin';
  static const _kDefault = '1234';

  static Future<String> get() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kKey) ?? _kDefault;
  }

  static Future<bool> isDefault() async => (await get()) == _kDefault;

  static Future<void> set(String pin) async {
    if (pin.length != 4 || !RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw Exception('Le PIN doit faire 4 chiffres');
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kKey, pin);
  }
}

// ============================================
// AGENT ORDER (in-progress order tracked by agent)
// ============================================
enum AgentOrderState { pending, paid, completed }

class AgentOrder {
  // Opaque token the backend issues. Replaces redeem_id in the agent surface
  // so the agent cannot bypass /cards/claim-with-code by manually hitting
  // /paygate/check-status with the redeem_id (which they no longer ever see).
  final String agentOrderToken;
  final String phone;
  final String holderName;
  final double amountUsd;
  final String flow; // 'activation' | 'recharge'
  final String cryptoAddress;
  final String amountUsdt;
  final DateTime createdAt;
  final AgentOrderState state;
  // 4-digit unlock code the agent must share with the user out-of-band.
  // Persisted locally so the agent can re-read it after restart.
  final String? claimCode;

  const AgentOrder({
    required this.agentOrderToken,
    required this.phone,
    required this.holderName,
    required this.amountUsd,
    required this.flow,
    required this.cryptoAddress,
    required this.amountUsdt,
    required this.createdAt,
    this.state = AgentOrderState.pending,
    this.claimCode,
  });

  AgentOrder copyWith({AgentOrderState? state}) => AgentOrder(
        agentOrderToken: agentOrderToken,
        phone: phone,
        holderName: holderName,
        amountUsd: amountUsd,
        flow: flow,
        cryptoAddress: cryptoAddress,
        amountUsdt: amountUsdt,
        createdAt: createdAt,
        state: state ?? this.state,
        claimCode: claimCode,
      );

  Map<String, dynamic> toJson() => {
        'agentOrderToken': agentOrderToken,
        'phone': phone,
        'holderName': holderName,
        'amountUsd': amountUsd,
        'flow': flow,
        'cryptoAddress': cryptoAddress,
        'amountUsdt': amountUsdt,
        'createdAt': createdAt.toIso8601String(),
        'state': state.name,
        'claimCode': claimCode,
      };

  factory AgentOrder.fromJson(Map<String, dynamic> j) => AgentOrder(
        agentOrderToken: j['agentOrderToken']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        holderName: j['holderName']?.toString() ?? '',
        amountUsd: (j['amountUsd'] as num?)?.toDouble() ?? 0.0,
        flow: j['flow']?.toString() ?? 'activation',
        cryptoAddress: j['cryptoAddress']?.toString() ?? '',
        amountUsdt: j['amountUsdt']?.toString() ?? '0',
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        state: AgentOrderState.values.firstWhere(
          (e) => e.name == (j['state']?.toString() ?? 'pending'),
          orElse: () => AgentOrderState.pending,
        ),
        claimCode: j['claimCode']?.toString(),
      );

  static const _kKey = 'agent_current_order';
  static const _kExpiryHrs = 48;

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kKey, jsonEncode(toJson()));
  }

  static Future<AgentOrder?> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kKey);
    if (raw == null) return null;
    try {
      final order = AgentOrder.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (DateTime.now().difference(order.createdAt).inHours > _kExpiryHrs) {
        await clear();
        return null;
      }
      return order;
    } catch (_) {
      await clear();
      return null;
    }
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kKey);
  }
}

// ============================================
// MAIN
// ============================================
// ============================================
// APP SETTINGS (theme + language)
// ============================================
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
    // Web (iPhone PWA) has no local_auth plugin — fall back to the PIN flow.
    if (kIsWeb) return true;
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
  static const _screens = [
    HomeScreen(),
    TransactionsScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    if (UserProfile.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _idx = 2);
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
                  _NavPill(icon: Icons.credit_card_rounded, label: 'Carte',     sel: _idx == 0, onTap: () => setState(() => _idx = 0)),
                  _NavPill(icon: Icons.receipt_long_rounded, label: 'Historique', sel: _idx == 1, onTap: () => setState(() => _idx = 1)),
                  _NavPill(icon: Icons.person_rounded,       label: 'Profil',    sel: _idx == 2, onTap: () => setState(() => _idx = 2)),
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

// ============================================
// HOME SCREEN
// ============================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  VccCard? _card;
  bool _loading = true;
  bool _showFull = false;
  bool _refreshing = false;
  // Card surfaced by an agent for this client's phone, ready to be redeemed.
  // Kept distinct from _card so the user explicitly opts in (we never auto-overwrite
  // an existing card on the device).
  Map<String, dynamic>? _pendingAgentCard;
  bool _pollingAgent = false;
  List<Map<String, dynamic>> _rates = [];
  String? _ratesDate;

  late AnimationController _shimmerCtrl;
  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;
  late AnimationController _bgCtrl;
  // Subtle continuous spin for the Tchipa "T" mark in the app bar — slow
  // enough to feel alive without distracting from the UI.
  late AnimationController _logoSpinCtrl;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _glowCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _glowAnim =
        CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);
    _bgCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 8))
      ..repeat(reverse: true);
    _logoSpinCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 16))
      ..repeat();
    _load();
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    _glowCtrl.dispose();
    _bgCtrl.dispose();
    _logoSpinCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final card = await VccCard.load();
    if (mounted) setState(() { _card = card; _loading = false; });
    _pollAgentCards();
    _loadRates();
  }

  // Parallel-market rates scraped by the backend from squareportsaid.com.
  // Best-effort: a failure just leaves the rates card hidden.
  Future<void> _loadRates() async {
    try {
      final resp = await http
          .get(Uri.parse('$kVpsBase/rates'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _rates = (j['rates'] as List).cast<Map<String, dynamic>>();
        _ratesDate = j['date'] as String?;
      });
    } catch (_) {/* leave the card hidden */}
  }

  Future<void> _pollAgentCards() async {
    if (_pollingAgent) return;
    final phone = UserProfile.phone.trim();
    if (phone.isEmpty) return;
    _pollingAgent = true;
    try {
      final cards = await PayGateService.fetchCardsForPhone(phone);
      // Locked cards come back with redeemId=null + cardToken set; unlocked
      // rows have redeemId set. Filter out the one we've already locally
      // claimed (matched by redeemId) and surface the next candidate.
      final localRedeem = _card?.redeemId;
      final candidate = cards.firstWhere(
        (c) {
          final cRedeem = c['redeemId']?.toString();
          return !(cRedeem != null && localRedeem != null && cRedeem == localRedeem);
        },
        orElse: () => <String, dynamic>{},
      );
      if (candidate.isNotEmpty && mounted) {
        setState(() => _pendingAgentCard = candidate);
      }
    } catch (_) {
      // Silent — non-critical background poll.
    } finally {
      _pollingAgent = false;
    }
  }

  Widget _buildAgentCardBanner() {
    final c = _pendingAgentCard!;
    final amt = (c['cardValue'] as num?)?.toStringAsFixed(0) ?? '?';
    return GestureDetector(
      onTap: _redeemAgentCard,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF22D3A1), Color(0xFF0EA47A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: const Color(0xFF22D3A1).withValues(alpha: 0.35),
                blurRadius: 18, offset: const Offset(0, 6)),
          ],
        ),
        child: Row(children: [
          const Icon(Icons.card_giftcard_rounded, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Une carte de \$$amt vous attend',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              const Text('Émise par un agent. Tapez pour récupérer.',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 26),
        ]),
      ),
    );
  }

  Future<void> _redeemAgentCard() async {
    final c = _pendingAgentCard;
    if (c == null) return;
    final cardToken    = c['cardToken']?.toString();
    final holderName   = c['holderName']?.toString() ?? UserProfile.name;
    final cardValue    = (c['cardValue'] as num?)?.toDouble() ?? 0.0;
    final requiresPin  = c['requiresPin'] == true;
    final requiresCode = c['requiresCode'] == true;

    // Locked path: backend hid both redeemLink and redeemId. Two unlock paths:
    //  - PIN flow (new): /cards/claim-with-pin with the user's own PIN.
    //  - Code flow (legacy): /cards/claim-with-code with a 4-digit code the
    //    agent shared out-of-band.
    String? link     = c['redeemLink']?.toString();
    String? redeemId = c['redeemId']?.toString();

    if (requiresPin || requiresCode ||
        link == null || link.isEmpty || redeemId == null || redeemId.isEmpty) {
      final phone = UserProfile.phone.trim();
      if (phone.isEmpty || cardToken == null || cardToken.isEmpty) return;
      final unlocked = requiresPin
          ? await _promptPinAndFetch(
              phone: phone, cardToken: cardToken, cardValue: cardValue)
          : await _promptClaimCodeAndFetch(
              phone: phone, cardToken: cardToken, cardValue: cardValue);
      if (unlocked == null) return; // user cancelled or kept failing
      link = unlocked.redeemLink;
      redeemId = unlocked.redeemId;
    }

    final base = VccCard(
      cardId: redeemId,
      redeemId: redeemId,
      redeemLink: link,
      balance: cardValue,
      isActivated: true,
      holderName: holderName,
    );
    await base.save();
    if (mounted) setState(() { _card = base; _pendingAgentCard = null; });

    if (!mounted) return;
    final unlockedLink = link;
    final unlockedRedeem = redeemId;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CardWebViewScreen(
          url: unlockedLink,
          title: 'Récupération carte…',
          onCardData: (number, cvv, expiry) async {
            final updated = base.copyWith(
                cardNumber: number, cvv: cvv, expiry: expiry);
            await updated.save();
            await PayGateService.markCardDelivered(unlockedRedeem);
            if (mounted) {
              Navigator.of(context).pop();
              setState(() => _card = updated);
            }
          },
        ),
      ),
    );
  }

  // Prompts the user for their own Tchipa PIN (set at install via PinSetup),
  // exchanges it via /cards/claim-with-pin. PIN is never shared with the
  // agent, so even a malicious agent who has phone+card_token can't claim.
  Future<({String redeemLink, String redeemId})?> _promptPinAndFetch({
    required String phone,
    required String cardToken,
    required double cardValue,
  }) async {
    final ctrl = TextEditingController();
    String? errorMsg;
    bool busy = false;
    ({String redeemLink, String redeemId})? result;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setDlg) {
        Future<void> submit() async {
          final pin = ctrl.text.trim();
          if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
            setDlg(() => errorMsg = 'PIN: 4 à 6 chiffres');
            return;
          }
          setDlg(() { busy = true; errorMsg = null; });
          try {
            final unlocked = await PayGateService.claimCardWithPin(
                phone: phone, cardToken: cardToken, pin: pin);
            result = unlocked;
            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
          } catch (e) {
            final msg = e.toString().replaceFirst('Exception: ', '');
            setDlg(() { busy = false; errorMsg = msg; });
            if (msg.toLowerCase().contains('trop de tentatives')) {
              await Future<void>.delayed(const Duration(seconds: 2));
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            }
          }
        }
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Récupérer ta carte',
              style: TextStyle(color: AppColors.label)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Une carte de \$${cardValue.toStringAsFixed(0)} t\'attend. '
              'Entre ton PIN Tchipa pour la déverrouiller.',
              style: TextStyle(color: AppColors.sublabel, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              enabled: !busy,
              keyboardType: TextInputType.number,
              obscureText: true,
              textAlign: TextAlign.center,
              maxLength: 6,
              style: TextStyle(
                  color: AppColors.inputFg,
                  fontSize: 22,
                  letterSpacing: 8,
                  fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                counterText: '',
                hintText: '••••',
              ),
              onSubmitted: (_) => submit(),
            ),
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
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Valider'),
            ),
          ],
        );
      }),
    );
    return result;
  }

  // Prompts the user for the 4-digit unlock code the agent shared
  // (Telegram/SMS), exchanges it via /cards/claim-with-code, and returns the
  // redeem link. Returns null if the user cancels. Loops on wrong code until
  // backend lockout (then closes with the lockout error).
  Future<({String redeemLink, String redeemId})?> _promptClaimCodeAndFetch({
    required String phone,
    required String cardToken,
    required double cardValue,
  }) async {
    final ctrl = TextEditingController();
    String? errorMsg;
    bool busy = false;
    ({String redeemLink, String redeemId})? result;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setDlg) {
        Future<void> submit() async {
          final code = ctrl.text.trim();
          if (code.length != 4 || int.tryParse(code) == null) {
            setDlg(() => errorMsg = 'Code à 4 chiffres requis');
            return;
          }
          setDlg(() { busy = true; errorMsg = null; });
          try {
            final unlocked = await PayGateService.claimCardWithCode(
                phone: phone, cardToken: cardToken, code: code);
            result = unlocked;
            if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
          } catch (e) {
            final msg = e.toString().replaceFirst('Exception: ', '');
            setDlg(() { busy = false; errorMsg = msg; });
            // Backend lockout — no point letting them retry.
            if (msg.toLowerCase().contains('trop de tentatives')) {
              await Future<void>.delayed(const Duration(seconds: 2));
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            }
          }
        }
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Déverrouiller la carte',
              style: TextStyle(color: AppColors.label)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Une carte de \$${cardValue.toStringAsFixed(0)} vous attend. '
              'Entrez le code à 4 chiffres communiqué par votre agent.',
              style: TextStyle(color: AppColors.sublabel, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              enabled: !busy,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 4,
              style: TextStyle(
                  color: AppColors.inputFg,
                  fontSize: 22,
                  letterSpacing: 8,
                  fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                counterText: '',
                hintText: '••••',
              ),
              onSubmitted: (_) => submit(),
            ),
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
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Valider'),
            ),
          ],
        );
      }),
    );
    return result;
  }

  Future<void> _refreshBalance() async {
    // PayGate has no balance API for VCCs — their own response says
    // "Consultez votre lien de carte PayGate pour le solde". The previous
    // implementation called fetchBalance (hardcoded to 0.0) and wrote 0
    // back to local storage, wiping the funded amount. We now just point
    // the user to Swype.
    _loadRates();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Solde temps réel non disponible. Ouvre le lien Swype pour voir le solde actuel.'),
      backgroundColor: AppColors.surface,
      duration: const Duration(seconds: 4),
    ));
  }

  void _showErr(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.redAccent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
    ));
  }

  void _onActivated(VccCard card) {
    setState(() => _card = card);
    VccTx.add(VccTx(
      type: 'activation',
      amount: kActivationFee,
      label: 'Activation carte VCC',
      date: DateTime.now(),
      isDebit: true,
    ));
  }

  void _onRechargeDone(double amount) {
    _load();
    VccTx.add(VccTx(
      type: 'recharge',
      amount: amount,
      label: 'Rechargement carte',
      date: DateTime.now(),
    ));
  }

  void _openActivation() {
    if (UserProfile.isEmpty) {
      _showErr('Complétez votre profil avant d\'activer');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ActivationSheet(
        onActivated: (card) { Navigator.pop(context); _onActivated(card); },
      ),
    );
  }

  void _openRecharge() {
    final card = _card;
    if (card?.isActivated != true) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RechargeSheet(
        card: card!,
        onSuccess: (amt) { Navigator.pop(context); _onRechargeDone(amt); },
      ),
    );
  }

  void _openDetails() {
    final card = _card;
    if (card?.isActivated != true) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CardDetailsSheet(card: card!),
    );
  }

  void _openCardLink() {
    final card = _card;
    final link = card?.redeemLink;
    if (link == null) return;
    bool extracted = false;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CardWebViewScreen(
          url: link,
          title: 'Récupération carte…',
          onCardData: (number, cvv, expiry) async {
            extracted = true;
            final updated = card!.copyWith(cardNumber: number, cvv: cvv, expiry: expiry);
            await updated.save();
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    ).then((_) async {
      if (!extracted || !mounted) return;
      final latest = await VccCard.load();
      if (!mounted) return;
      if (latest != null) setState(() => _card = latest);
      if (latest?.cardNumber != null) {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => _CardDetailsSheet(card: latest!),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(children: [
        // Animated mesh gradient background
        AnimatedBuilder(
          animation: _bgCtrl,
          builder: (_, __) {
            final t = _bgCtrl.value;
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1 + t * 0.6, -1),
                  end: Alignment(1 - t * 0.4, 1),
                  colors: AppColors.isDark
                      ? [
                          Color.lerp(const Color(0xFF0D1117), const Color(0xFF0A1628), t)!,
                          Color.lerp(const Color(0xFF0F1923), const Color(0xFF120820), t)!,
                          Color.lerp(const Color(0xFF0D1117), const Color(0xFF0A1020), t)!,
                        ]
                      : [
                          Color.lerp(const Color(0xFFEEF4FF), const Color(0xFFF5F0FF), t)!,
                          Color.lerp(const Color(0xFFF0F5FF), const Color(0xFFEFF8FF), t)!,
                          Color.lerp(const Color(0xFFF5F0FF), const Color(0xFFEEF4FF), t)!,
                        ],
                ),
              ),
            );
          },
        ),
        // Cyan blob top-right
        Positioned(
          top: -80, right: -60,
          child: AnimatedBuilder(
            animation: _bgCtrl,
            builder: (_, __) => Container(
              width: 320, height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  const Color(0xFF00D4FF).withValues(alpha: (AppColors.isDark ? 0.10 : 0.18) + _bgCtrl.value * 0.06),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
        ),
        // Purple blob bottom-left
        Positioned(
          bottom: 80, left: -80,
          child: AnimatedBuilder(
            animation: _bgCtrl,
            builder: (_, __) => Container(
              width: 300, height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  const Color(0xFF8B5CF6).withValues(alpha: (AppColors.isDark ? 0.08 : 0.12) + (1 - _bgCtrl.value) * 0.05),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
        ),
        CustomScrollView(slivers: [
        SliverAppBar(
          floating: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 16,
          title: Row(children: [
            RotationTransition(
              turns: _logoSpinCtrl,
              child: Container(
                width: 44, height: 44,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x7300D4FF),
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Image.asset('assets/tchipa_logo.png', fit: BoxFit.contain),
              ),
            ),
            const SizedBox(width: 12),
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
              ).createShader(b),
              child: const Text('tchipa',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 4,
                  )),
            ),
          ]),
          actions: [
            if (_card?.isActivated == true)
              IconButton(
                tooltip: 'Actualiser le solde',
                onPressed: _refreshing ? null : _refreshBalance,
                icon: _refreshing
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF00D4FF)))
                    : const Icon(Icons.refresh_rounded,
                        color: Color(0xFF00D4FF)),
              ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: _loading
              ? const _LoadingCard()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSubtitle(),
                      const SizedBox(height: 16),
                      if (_pendingAgentCard != null) ...[
                        _buildAgentCardBanner(),
                        const SizedBox(height: 14),
                      ],
                      _buildCardWidget(),
                      const SizedBox(height: 24),
                      _buildActions(),
                      if (_rates.isNotEmpty) ...[
                        const SizedBox(height: 32),
                        _buildRates(),
                      ],
                      if (_card?.isActivated == true) ...[
                        const SizedBox(height: 32),
                        _buildRecentActivity(),
                      ],
                    ],
                  ),
                ),
        ),
      ]),
      ]), // close Stack
    );
  }

  Widget _buildSubtitle() {
    final active = _card?.isActivated == true;
    final name = UserProfile.name.isNotEmpty ? UserProfile.name.split(' ').first : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(name != null ? 'Bonjour, $name' : 'Bonjour',
            style: TextStyle(color: AppColors.label, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF00D4FF).withValues(alpha: 0.12)
                : AppColors.card.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active
                  ? const Color(0xFF00D4FF).withValues(alpha: 0.35)
                  : AppColors.border,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? const Color(0xFF00D4FF) : AppColors.textDim,
                boxShadow: active ? [BoxShadow(color: const Color(0xFF00D4FF).withValues(alpha: 0.6), blurRadius: 4)] : null,
              ),
            ),
            const SizedBox(width: 5),
            Text(active ? 'Active' : 'Inactive',
                style: TextStyle(
                    color: active ? const Color(0xFF00D4FF) : AppColors.textDim,
                    fontSize: 11, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      if (active) ...[
        Text('SOLDE DISPONIBLE',
            style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 2.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('\$', style: TextStyle(color: AppColors.textSub, fontSize: 22, fontWeight: FontWeight.w300, height: 1.6)),
          const SizedBox(width: 2),
          Text(_card!.balance.toStringAsFixed(2),
              style: TextStyle(
                  color: AppColors.label,
                  fontSize: 48,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  height: 1)),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF00D4FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.3)),
              ),
              child: const Text('USD', style: TextStyle(color: Color(0xFF00D4FF), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
            ),
          ),
        ]),
      ] else
        Text('Activez votre carte pour commencer',
            style: TextStyle(color: AppColors.textSub, fontSize: 13)),
    ]);
  }

  Widget _buildCardWidget() {
    return GestureDetector(
      onTap: () {
        if (_card?.isActivated == true) {
          setState(() => _showFull = !_showFull);
          HapticFeedback.lightImpact();
        }
      },
      child: AnimatedBuilder(
        animation: _shimmerCtrl,
        builder: (_, __) => _VccCardVisual(
          card: _card,
          showFull: _showFull,
          shimmerPhase: _shimmerCtrl.value,
          onCardCaptured: () async {
            final latest = await VccCard.load();
            if (!mounted) return;
            if (latest != null) setState(() => _card = latest);
          },
        ),
      ),
    );
  }

  static String _fmtRate(dynamic n) {
    final d = (n as num).toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
  }

  Widget _buildRates() {
    final usdt = _rates.firstWhere((r) => r['code'] == 'USDT',
        orElse: () => const {});
    final others = _rates.where((r) => r['code'] != 'USDT').toList();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: AppColors.isDark ? 0.7 : 1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Taux du Square',
                style: TextStyle(
                    color: AppColors.label,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            if (_ratesDate != null)
              Text(_ratesDate!,
                  style: TextStyle(color: AppColors.textDim, fontSize: 11)),
          ]),
          const SizedBox(height: 14),
          if (usdt.isNotEmpty) _usdtRateFeature(usdt),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: others.map(_rateChip).toList(),
            ),
          ],
          const SizedBox(height: 12),
          Text('Marché parallèle · squareportsaid.com',
              style: TextStyle(color: AppColors.textDim, fontSize: 10.5)),
        ],
      ),
    );
  }

  // USDT first and biggest — the currency the wallet pipeline runs on.
  Widget _usdtRateFeature(Map<String, dynamic> r) {
    const tether = Color(0xFF26A17B);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          tether.withValues(alpha: 0.16),
          tether.withValues(alpha: 0.04),
        ]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tether.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: tether, shape: BoxShape.circle),
          child: const Text('₮',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('USDT',
              style: TextStyle(
                  color: AppColors.label,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
          Text('Tether · DZD',
              style: TextStyle(color: AppColors.textSub, fontSize: 12)),
        ]),
        const Spacer(),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_fmtRate(r['buy']),
              style: TextStyle(
                  color: AppColors.label,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  height: 1)),
          const SizedBox(height: 2),
          Text('Achat · Vente ${_fmtRate(r['sell'])}',
              style: TextStyle(color: AppColors.textSub, fontSize: 11.5)),
        ]),
      ]),
    );
  }

  Widget _rateChip(Map<String, dynamic> r) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(r['code'] as String,
            style: TextStyle(
                color: AppColors.label,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Text('${_fmtRate(r['buy'])} / ${_fmtRate(r['sell'])}',
            style: TextStyle(color: AppColors.textSub, fontSize: 12.5)),
      ]),
    );
  }

  Widget _buildActions() {
    final active = _card?.isActivated == true;

    if (!active) {
      return Column(children: [
        AnimatedBuilder(
          animation: _glowAnim,
          builder: (_, child) {
            final g = _glowAnim.value;
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00D4FF)
                        .withValues(alpha: 0.25 + g * 0.35),
                    blurRadius: 18 + g * 20,
                    spreadRadius: g * 4,
                  ),
                  BoxShadow(
                    color: const Color(0xFF8B5CF6)
                        .withValues(alpha: 0.2 + g * 0.25),
                    blurRadius: 28 + g * 16,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: _ActionButton(
            label: 'Activer ma carte',
            sublabel: 'Paiement direct USDT · Réseau Polygon',
            icon: Icons.credit_card_rounded,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _openActivation,
          ),
        ),
        const SizedBox(height: 16),
        _TelegramButton(),
      ]).animate().fadeIn(duration: 400.ms).slideY(begin: 0.08, end: 0);
    }

    return Column(children: [
      _ActionButton(
        label: 'Recharger',
        sublabel: 'Créer une nouvelle carte',
        icon: Icons.add_card_rounded,
        colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
        onTap: _openRecharge,
      ),
      const SizedBox(height: 12),
      if (_card?.cardNumber == null && _card?.redeemLink != null)
        _ActionButton(
          label: 'Récupérer ma carte',
          sublabel: 'Extraction automatique des détails',
          icon: Icons.credit_card_rounded,
          colors: const [Color(0xFF8B5CF6), Color(0xFFEC4899)],
          onTap: _openCardLink,
        )
      else
        _ActionButton(
          label: 'Voir les détails',
          sublabel: 'Numéro · CVV · Expiration',
          icon: Icons.visibility_rounded,
          colors: const [Color(0xFF8B5CF6), Color(0xFFEC4899)],
          onTap: _openDetails,
        ),
      const SizedBox(height: 12),
      _TelegramButton(),
    ]).animate().fadeIn(duration: 400.ms);
  }

  Widget _buildRecentActivity() {
    return FutureBuilder<List<VccTx>>(
      future: VccTx.loadAll(),
      builder: (ctx, snap) {
        final txs = (snap.data ?? []).take(3).toList();
        if (txs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ACTIVITÉ RÉCENTE',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ...txs.map((tx) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TxRow(tx: tx),
                )),
          ],
        );
      },
    );
  }
}

// ============================================
// VCC CARD VISUAL
// ============================================
class _VccCardVisual extends StatelessWidget {
  final VccCard? card;
  final bool showFull;
  final double shimmerPhase;
  // Called after the user captures card data from the embedded WebView
  // (auto-extracted or via manual entry). The parent uses this to reload
  // the persisted card and trigger setState.
  final Future<void> Function()? onCardCaptured;

  const _VccCardVisual({
    required this.card,
    required this.showFull,
    required this.shimmerPhase,
    this.onCardCaptured,
  });

  @override
  Widget build(BuildContext context) {
    final active = card?.isActivated == true;
    String _rawName = card?.holderName?.isNotEmpty == true
        ? card!.holderName!
        : UserProfile.name.isNotEmpty
            ? UserProfile.name
            : 'NOM COMPLET';
    // strip email address if accidentally included
    if (_rawName.contains('@')) _rawName = _rawName.split(RegExp(r'[\s<@]')).first;
    final holderName = _rawName.toUpperCase();

    return Container(
      height: 216,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: active
              ? const [
                  Color(0xFF1B0B3A),
                  Color(0xFF0A1F6E),
                  Color(0xFF003D5C),
                ]
              : const [
                  Color(0xFF1A1A2E),
                  Color(0xFF16213E),
                  Color(0xFF0F3460),
                ],
        ),
        boxShadow: [
          BoxShadow(
            color: active
                ? const Color(0xFF00D4FF).withValues(alpha: 0.30)
                : const Color(0xFF0F3460).withValues(alpha: 0.45),
            blurRadius: 32, offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: const Color(0xFF8B5CF6).withValues(alpha: 0.18),
            blurRadius: 48, offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(children: [
          // Subtle grid lines
          Positioned.fill(
              child: CustomPaint(
                  painter: _CardGridPainter(active))),
          // Moving shine (active only)
          if (active)
            Positioned.fill(
                child: CustomPaint(
                    painter: _ShimmerPainter(shimmerPhase))),
          // Card content
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    _buildChip(active),
                    _buildBalance(active),
                  ],
                ),
                const Spacer(),
                _buildNumberRow(active, context),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                        child: _buildNameExpiry(
                            active, holderName)),
                    _buildLogo(active),
                  ],
                ),
              ],
            ),
          ),
          // Tap hint
          if (active)
            Positioned(
              bottom: 6, left: 0, right: 0,
              child: Center(
                child: Text(
                  showFull
                      ? 'Appuyer pour masquer'
                      : 'Appuyer pour révéler le numéro',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _buildChip(bool active) {
    return Container(
      width: 46, height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: active
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFD700), Color(0xFFB8860B)])
            : LinearGradient(colors: [
                Colors.grey.shade700,
                Colors.grey.shade900,
              ]),
      ),
      child: active
          ? null
          : const Center(
              child: Icon(Icons.lock_outline_rounded,
                  color: Colors.white30, size: 16)),
    );
  }

  Widget _buildBalance(bool active) {
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(
        active ? 'SOLDE DISPONIBLE' : 'NON ACTIVÉE',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 9, letterSpacing: 1.5,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        active ? '\$${card!.balance.toStringAsFixed(2)}' : '——',
        style: TextStyle(
          color: active ? Colors.white : Colors.white38,
          fontSize: active ? 24 : 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      if (active)
        Text('USD',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 10,
                letterSpacing: 1)),
    ]);
  }

  Widget _buildNumberRow(bool active, BuildContext context) {
    if (!active) {
      // blurred placeholder — BackdropFilter blurs everything behind it
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Container(
            padding: const EdgeInsets.symmetric(
                vertical: 4, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '•••• •••• •••• ••••',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 20,
                letterSpacing: 3.5,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }
    final hasNumber = card!.cardNumber != null && card!.cardNumber!.isNotEmpty;
    if (!hasNumber) {
      final link = card!.redeemLink;
      return GestureDetector(
        onTap: link != null
            ? () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CardWebViewScreen(
                    url: link,
                    title: 'Récupération carte…',
                    onCardData: (number, cvv, expiry) async {
                      final updated = card!.copyWith(
                          cardNumber: number, cvv: cvv, expiry: expiry);
                      await updated.save();
                      final rid = card!.redeemId ?? card!.cardId;
                      if (rid != null && rid.isNotEmpty) {
                        try { await PayGateService.markCardDelivered(rid); }
                        catch (_) {}
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ));
                if (onCardCaptured != null) await onCardCaptured!();
              }
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Voir ma carte',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                letterSpacing: 0.5,
                fontStyle: FontStyle.italic,
                decoration: link != null ? TextDecoration.underline : null,
                decorationColor: Colors.white54,
              ),
            ),
            if (link != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.open_in_new_rounded,
                  size: 13, color: Colors.white.withValues(alpha: 0.55)),
            ],
          ],
        ),
      );
    }
    return Text(
      showFull ? card!.formattedNumber : card!.maskedNumber,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        letterSpacing: 3.5,
        fontFamily: 'monospace',
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildNameExpiry(bool active, String holderName) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('TITULAIRE',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 8,
              letterSpacing: 1.5)),
      const SizedBox(height: 2),
      Text(
        holderName,
        style: TextStyle(
          color: active
              ? Colors.white
              : Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
          letterSpacing: 0.8,
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Text('EXP  ',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 8,
                letterSpacing: 1.5)),
        if (!active)
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: Text('••/••',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12,
                    letterSpacing: 1.5,
                  )),
            ),
          )
        else
          Text(card!.expiry ?? '——',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  letterSpacing: 1.5)),
      ]),
    ]);
  }

  Widget _buildLogo(bool active) {
    return SizedBox(
      width: 46, height: 28,
      child: Stack(children: [
        Positioned(
          left: 0,
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? const Color(0xFFEB001B).withValues(alpha: 0.85)
                  : Colors.grey.shade800.withValues(alpha: 0.4),
            ),
          ),
        ),
        Positioned(
          right: 0,
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? const Color(0xFFF79E1B).withValues(alpha: 0.85)
                  : Colors.grey.shade700.withValues(alpha: 0.4),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double phase;
  _ShimmerPainter(this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    final x = phase * (size.width + 240) - 120;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.13),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0, 0.3, 0.5, 0.7, 1],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Rect.fromLTWH(x - 120, 0, 240, size.height));
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => phase != old.phase;
}

class _CardGridPainter extends CustomPainter {
  final bool active;
  _CardGridPainter(this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: active ? 0.04 : 0.02)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 8; i++) {
      canvas.drawLine(Offset(size.width * i / 8, 0),
          Offset(size.width * i / 8, size.height), paint);
    }
    for (var i = 1; i < 5; i++) {
      canvas.drawLine(Offset(0, size.height * i / 5),
          Offset(size.width, size.height * i / 5), paint);
    }
  }

  @override
  bool shouldRepaint(_CardGridPainter old) => false;
}

// ============================================
// ACTION BUTTON
// ============================================
class _ActionButton extends StatefulWidget {
  final String label;
  final String sublabel;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.97),
      onTapUp: (_) { setState(() => _scale = 1.0); widget.onTap(); },
      onTapCancel: () => setState(() => _scale = 1.0),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.colors,
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: widget.colors.first.withValues(alpha: 0.35),
                blurRadius: 18, offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: widget.colors.last.withValues(alpha: 0.20),
                blurRadius: 28, offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(widget.icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(widget.sublabel,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.70),
                          fontSize: 11)),
                ],
              ),
              const Spacer(),
              Icon(Icons.arrow_forward_ios_rounded,
                  color: Colors.white.withValues(alpha: 0.5), size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

class _TelegramButton extends StatelessWidget {
  const _TelegramButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        try {
          await launchUrl(Uri.parse(kAgentTelegram),
              mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0088CC), Color(0xFF229ED9)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0088CC).withValues(alpha: 0.5),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40, height: 40,
              decoration: const BoxDecoration(
                color: Colors.white24,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.telegram_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Commander via Telegram',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 3),
                  Text('Un agent traite ta commande rapidement',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11.5)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: Colors.white54, size: 16),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Container(
        height: 216,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Center(
            child: CircularProgressIndicator(
                color: Color(0xFF00D4FF), strokeWidth: 2)),
      ),
    );
  }
}

// ============================================
// TRANSACTION ROW
// ============================================
class _TxRow extends StatelessWidget {
  final VccTx tx;
  const _TxRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final color =
        tx.isDebit ? Colors.redAccent : const Color(0xFF00D4FF);
    final sign = tx.isDebit ? '-' : '+';
    final IconData ico;
    switch (tx.type) {
      case 'activation':
        ico = Icons.credit_card_rounded;
        break;
      case 'recharge':
        ico = Icons.add_card_rounded;
        break;
      default:
        ico = Icons.shopping_bag_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.isDark ? null : [
          BoxShadow(
            color: const Color(0xFF6B8EF2).withValues(alpha: 0.07),
            blurRadius: 12, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(ico, color: color, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx.label,
                  style: TextStyle(
                      color: AppColors.label, fontSize: 14,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 3),
              Text(
                '${tx.date.day.toString().padLeft(2, '0')}/'
                '${tx.date.month.toString().padLeft(2, '0')}/'
                '${tx.date.year}  '
                '${tx.date.hour.toString().padLeft(2, '0')}:'
                '${tx.date.minute.toString().padLeft(2, '0')}',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 11),
              ),
            ],
          ),
        ),
        Text('$sign\$${tx.amount.toStringAsFixed(2)}',
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
      ]),
    );
  }
}

// ============================================
// ACTIVATION SHEET
// ============================================
enum _ActStep { pick, paying, checking, done }

class _ActivationSheet extends StatefulWidget {
  final void Function(VccCard) onActivated;
  const _ActivationSheet({required this.onActivated});
  @override
  State<_ActivationSheet> createState() => _ActivationSheetState();
}

class _ActivationSheetState extends State<_ActivationSheet> {
  static const _kFlow = 'activation';
  _ActStep _step = _ActStep.pick;
  double _amount = 10.0;
  static const _presets = [10.0, 20.0, 50.0, 100.0];
  static const _kMargin = 0.10;
  bool _customMode = false;
  final _customCtrl = TextEditingController();
  static double _estimatedUsdt(double cardValue) =>
      double.parse((cardValue * 1.0664 * (1 + _kMargin)).toStringAsFixed(2));
  VccOrder? _order;
  String? _redeemLink;
  VccCard? _activatedCard;
  String? _error;
  Timer? _autoPoll;

  @override
  void initState() {
    super.initState();
    _restorePending();
  }

  @override
  void dispose() {
    _autoPoll?.cancel();
    _customCtrl.dispose();
    super.dispose();
  }

  Future<void> _restorePending() async {
    final pending = await VccOrder.loadPending(_kFlow);
    if (pending != null && mounted) {
      setState(() {
        _order = pending;
        _amount = pending.cardValue;
        _step = _ActStep.paying;
      });
      _startAutoPoll();
    }
  }

  void _startAutoPoll() {
    _autoPoll?.cancel();
    _autoPoll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_step == _ActStep.paying && _order != null) {
        _checkStatus(silent: true);
      }
    });
  }

  Future<void> _cancelPending() async {
    _autoPoll?.cancel();
    await VccOrder.clearPending(_kFlow);
    if (mounted) {
      setState(() {
        _order = null;
        _error = null;
        _step = _ActStep.pick;
      });
    }
  }

  Future<void> _createOrder() async {
    setState(() { _step = _ActStep.paying; _error = null; _order = null; });
    try {
      final order = await PayGateService.createVccOrder(
        amount: _amount,
        holderName: UserProfile.name,
        phone: UserProfile.phone,
        source: 'self',
      );
      await order.savePending(_kFlow);
      if (!mounted) return;
      setState(() => _order = order);
      _startAutoPoll();
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _ActStep.pick;
      });
    }
  }

  Future<void> _checkStatus({bool silent = false}) async {
    final id = _order?.redeemId;
    if (id == null) return;
    if (!silent) setState(() { _step = _ActStep.checking; _error = null; });
    try {
      final status = await PayGateService.checkVccStatus(id);
      if (status['isReady'] == true) {
        _autoPoll?.cancel();
        await VccOrder.clearPending(_kFlow);
        final link = status['redeemLink'] as String?;
        final card = VccCard(
          cardId: id,
          redeemId: id,
          redeemLink: link,
          balance: _order!.cardValue,
          isActivated: true,
          holderName: UserProfile.name,
        );
        await card.save();
        await PayGateService.markCardDelivered(id);
        _activatedCard = card;
        if (mounted) setState(() { _redeemLink = link; _step = _ActStep.done; });
        widget.onActivated(card);
      } else if (status['isPaid'] == true) {
        if (silent) return; // auto-poll: keep waiting silently
        setState(() {
          _error = 'Paiement reçu — carte en cours d\'émission, revérifiez dans 1 min.';
          _step = _ActStep.paying;
        });
      } else {
        if (silent) return; // auto-poll: stay on payment screen without nagging
        setState(() {
          _error = 'Paiement non reçu. Vérifiez que vous avez envoyé exactement ${_order!.amountUsdt} USDT sur Polygon.';
          _step = _ActStep.paying;
        });
      }
    } catch (e) {
      if (silent) return; // auto-poll: ignore transient network errors
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _ActStep.paying;
      });
    }
  }

  void _openLink() {
    final link = _redeemLink;
    final card = _activatedCard;
    if (link == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardWebViewScreen(
        url: link,
        title: 'Récupération carte…',
        onCardData: card == null ? null : (number, cvv, expiry) async {
          final updated = card.copyWith(cardNumber: number, cvv: cvv, expiry: expiry);
          await updated.save();
          widget.onActivated(updated);
          if (mounted) {
            Navigator.of(context).pop(); // ferme WebView
            Navigator.of(context).pop(); // ferme bottom sheet
          }
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: AppColors.isDark
              ? [const Color(0xFF111827), const Color(0xFF0D1117)]
              : [Colors.white, const Color(0xFFF0F5FF)],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: Column(children: [
              Center(child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2)),
              )),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.credit_card_rounded, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Text(_step == _ActStep.done ? 'Carte activée !' : 'Activer ma carte',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 28),
            child: switch (_step) {
              _ActStep.pick     => _buildPicker(),
              _ActStep.paying   => _buildPayment(),
              _ActStep.checking => _buildChecking(),
              _ActStep.done     => _buildDone(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPicker() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(L.chooseAmount,
              style: TextStyle(color: AppColors.text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(L.payDirectly,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),
          // Presets + bouton Autre
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ..._presets.map((amt) {
                final sel = !_customMode && _amount == amt;
                return GestureDetector(
                  onTap: () => setState(() { _customMode = false; _amount = amt; }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: sel ? const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]) : null,
                      color: sel ? null : AppColors.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: sel ? Colors.transparent
                              : Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('\$${amt.toStringAsFixed(0)}',
                          style: TextStyle(
                              color: sel ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('${(_estimatedUsdt(amt) * kExchangeRate).toStringAsFixed(0)} DA',
                          style: TextStyle(
                              color: sel ? Colors.black54 : Colors.white38,
                              fontSize: 10)),
                    ]),
                  ),
                );
              }),
              // Bouton Autre
              GestureDetector(
                onTap: () => setState(() { _customMode = true; }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: _customMode ? const Color(0xFF8B5CF6) : AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _customMode ? Colors.transparent
                            : Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Text('Autre',
                      style: TextStyle(
                          color: _customMode ? Colors.white : AppColors.textSub,
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
          // Champ montant libre
          if (_customMode) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _customCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: AppColors.text, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                prefixText: '\$ ',
                prefixStyle: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold),
                hintText: 'Montant en USD (min \$5)',
                hintStyle: TextStyle(color: AppColors.textDim),
                filled: true,
                fillColor: AppColors.card,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 2)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
              ),
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed >= 5) setState(() => _amount = parsed);
              },
            ),
          ],
          const SizedBox(height: 16),
          // Récap estimé
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.2)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Carte Mastercard',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
              Text('≈ ${_estimatedUsdt(_amount)} USDT',
                  style: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold)),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          _gradientBtn(
            label: L.createOrder,
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: () {
              if (_customMode) {
                final v = double.tryParse(_customCtrl.text);
                if (v == null || v < 5) {
                  setState(() => _error = 'Montant minimum : \$5');
                  return;
                }
                _amount = v;
              }
              _createOrder();
            },
          ),
          const SizedBox(height: 16),
          // Option agent Telegram
          GestureDetector(
            onTap: () async {
              try {
                await launchUrl(Uri.parse(kAgentTelegram),
                    mode: LaunchMode.externalApplication);
              } catch (_) {}
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0088CC), Color(0xFF229ED9)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0088CC).withValues(alpha: 0.45),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.telegram_rounded, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  const Text('Passer commande via un Agent',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 6),
                Text('Rejoins le groupe Telegram · envoi ton nom + montant',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11.5)),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  static String _paymentUri(String toAddress, String amountUsdt) {
    const usdtPolygon = '0xc2132D05D31c914a87C6611C10748AEb04B58e8F';
    final micro = (double.tryParse(amountUsdt) ?? 0) * 1e6;
    return 'ethereum:$usdtPolygon@137/transfer?address=$toAddress&uint256=${micro.toStringAsFixed(0)}';
  }

  Widget _buildPayment() {
    final order = _order;
    if (order == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
      );
    }
    final addr = order.cryptoAddress;
    final qrData = _paymentUri(addr, order.amountUsdt);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(L.sendExactly,
              style: TextStyle(color: AppColors.text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(L.usdtPolygonOnly,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.4)),
            ),
            child: Column(children: [
              Text(L.exactAmount,
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Text('${order.amountUsdt} USDT',
                  style: const TextStyle(color: Color(0xFF00D4FF),
                      fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('carte \$${order.cardValue.toStringAsFixed(0)} · réseau Polygon',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.white,
                  child: QrImageView(data: qrData, size: 150, version: QrVersions.auto),
                ),
              ),
              const SizedBox(height: 12),
              Text('ADRESSE USDT (POLYGON)',
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(addr,
                      style: TextStyle(color: AppColors.textSub, fontSize: 11,
                          fontFamily: 'monospace'),
                      maxLines: 2),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: addr));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Adresse copiée'),
                      duration: Duration(seconds: 2),
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.copy_rounded, color: Color(0xFF00D4FF), size: 18),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Text(
              '⚠ Envoyez uniquement sur le réseau Polygon. Tout envoi sur un autre réseau sera perdu.',
              style: TextStyle(color: Colors.amber.withValues(alpha: 0.9), fontSize: 12),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orange, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          _gradientBtn(
            label: 'J\'ai payé — Vérifier',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
            onTap: () => _checkStatus(),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('ID: ${order.redeemId}',
                style: TextStyle(color: AppColors.textDim, fontSize: 10,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _cancelPending,
                child: const Text('Nouvelle commande',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fermer',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChecking() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: Color(0xFF00D4FF)),
        const SizedBox(height: 20),
        const Text('Vérification du paiement…',
            style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 24),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Retour', style: TextStyle(color: Colors.white38)),
        ),
      ]),
    );
  }

  Widget _buildDone() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.black, size: 36),
          ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
        ),
        const SizedBox(height: 20),
        const Text('Carte activée !',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Votre carte VCC Mastercard est prête.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
        const SizedBox(height: 24),
        if (_redeemLink != null)
          _gradientBtn(
            label: 'Voir ma carte',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _openLink,
          ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Feature({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(icon, color: const Color(0xFF00D4FF), size: 18),
        const SizedBox(width: 12),
        Text(text,
            style: const TextStyle(
                color: Colors.white70, fontSize: 14)),
      ]),
    );
  }
}

// ============================================
// RECHARGE SHEET
// ============================================
enum _RechStep { pick, paying, checking, done }

class _RechargeSheet extends StatefulWidget {
  final VccCard card;
  final void Function(double) onSuccess;
  const _RechargeSheet({required this.card, required this.onSuccess});
  @override
  State<_RechargeSheet> createState() => _RechargeSheetState();
}

class _RechargeSheetState extends State<_RechargeSheet> {
  static const _kFlow = 'recharge';
  _RechStep _step = _RechStep.pick;
  double _amount = 20.0;
  static const _presets = [10.0, 20.0, 50.0, 100.0];
  static const _kMargin = 0.10;
  static double _estimatedUsdt(double v) =>
      double.parse((v * 1.0664 * (1 + _kMargin)).toStringAsFixed(2));
  VccOrder? _order;
  String? _error;
  String? _redeemLink;
  VccCard? _rechargedCard;
  Timer? _autoPoll;

  @override
  void initState() {
    super.initState();
    _restorePending();
  }

  @override
  void dispose() {
    _autoPoll?.cancel();
    super.dispose();
  }

  Future<void> _restorePending() async {
    final pending = await VccOrder.loadPending(_kFlow);
    if (pending != null && mounted) {
      setState(() {
        _order = pending;
        _amount = pending.cardValue;
        _step = _RechStep.paying;
      });
      _startAutoPoll();
    }
  }

  void _startAutoPoll() {
    _autoPoll?.cancel();
    _autoPoll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_step == _RechStep.paying && _order != null) {
        _checkStatus(silent: true);
      }
    });
  }

  Future<void> _cancelPending() async {
    _autoPoll?.cancel();
    await VccOrder.clearPending(_kFlow);
    if (mounted) {
      setState(() {
        _order = null;
        _error = null;
        _step = _RechStep.pick;
      });
    }
  }

  Future<void> _createOrder() async {
    setState(() { _step = _RechStep.paying; _error = null; _order = null; });
    try {
      final order = await PayGateService.createVccOrder(
        amount: _amount,
        holderName: UserProfile.name,
        phone: UserProfile.phone,
        source: 'self',
      );
      await order.savePending(_kFlow);
      if (!mounted) return;
      setState(() => _order = order);
      _startAutoPoll();
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _RechStep.pick;
      });
    }
  }

  Future<void> _checkStatus({bool silent = false}) async {
    final id = _order?.redeemId;
    if (id == null) return;
    if (!silent) setState(() { _step = _RechStep.checking; _error = null; });
    try {
      final status = await PayGateService.checkVccStatus(id);
      if (status['isReady'] == true) {
        _autoPoll?.cancel();
        await VccOrder.clearPending(_kFlow);
        final link = status['redeemLink'] as String?;
        final card = VccCard(
          cardId: id,
          redeemId: id,
          redeemLink: link,
          balance: _order!.cardValue,
          isActivated: true,
          holderName: UserProfile.name,
        );
        await card.save();
        await PayGateService.markCardDelivered(id);
        _rechargedCard = card;
        if (mounted) setState(() { _redeemLink = link; _step = _RechStep.done; });
        widget.onSuccess(_order!.cardValue);
      } else if (status['isPaid'] == true) {
        if (silent) return;
        setState(() {
          _error = 'Paiement reçu — carte en cours d\'émission, revérifiez dans 1 min.';
          _step = _RechStep.paying;
        });
      } else {
        if (silent) return;
        setState(() {
          _error = 'Paiement non reçu. Vérifiez que vous avez envoyé exactement ${_order!.amountUsdt} USDT sur Polygon.';
          _step = _RechStep.paying;
        });
      }
    } catch (e) {
      if (silent) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _RechStep.paying;
      });
    }
  }

  void _openLink() {
    final link = _redeemLink;
    final card = _rechargedCard;
    if (link == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardWebViewScreen(
        url: link,
        title: 'Récupération carte…',
        onCardData: card == null ? null : (number, cvv, expiry) async {
          final updated = card.copyWith(cardNumber: number, cvv: cvv, expiry: expiry);
          await updated.save();
          if (mounted) {
            Navigator.of(context).pop(); // ferme WebView
            Navigator.of(context).pop(); // ferme bottom sheet
          }
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: AppColors.isDark
            ? [const Color(0xFF111827), const Color(0xFF0D1117)]
            : [Colors.white, const Color(0xFFF0F5FF)],
      ),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0096FF)]),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
          child: Column(children: [
            Center(child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            )),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.add_card_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Text(_step == _RechStep.done ? 'Carte créée !' : 'Nouvelle carte VCC',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 28),
          child: switch (_step) {
            _RechStep.pick     => _buildSelector(),
            _RechStep.paying   => _buildPayment(),
            _RechStep.checking => _buildChecking(),
            _RechStep.done     => _buildDone(),
          },
        ),
      ],
    ),
  );

  Widget _buildSelector() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Nouvelle carte VCC',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('Payez directement en USDT sur le réseau Polygon',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
        const SizedBox(height: 22),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 4,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: _presets.map((amt) {
            final sel = _amount == amt;
            return GestureDetector(
              onTap: () => setState(() => _amount = amt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  gradient: sel
                      ? const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0096FF)])
                      : null,
                  color: sel ? null : AppColors.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: sel ? Colors.transparent : Colors.white.withValues(alpha: 0.08)),
                  boxShadow: sel
                      ? [BoxShadow(color: const Color(0xFF00D4FF).withValues(alpha: 0.3), blurRadius: 10)]
                      : [],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('\$$amt',
                        style: TextStyle(
                            color: sel ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('${_estimatedUsdt(amt)} USDT',
                        style: TextStyle(
                            color: sel ? Colors.black54 : Colors.white38, fontSize: 10)),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total à payer',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              Text('${_estimatedUsdt(_amount)} USDT',
                  style: const TextStyle(
                      color: Color(0xFF00D4FF),
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],
        const SizedBox(height: 20),
        _gradientBtn(
          label: 'Créer ma commande',
          loading: false,
          colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
          onTap: _createOrder,
        ),
      ],
    );
  }

  static String _paymentUri(String toAddress, String amountUsdt) {
    const usdtPolygon = '0xc2132D05D31c914a87C6611C10748AEb04B58e8F';
    final micro = (double.tryParse(amountUsdt) ?? 0) * 1e6;
    return 'ethereum:$usdtPolygon@137/transfer?address=$toAddress&uint256=${micro.toStringAsFixed(0)}';
  }

  Widget _buildPayment() {
    final order = _order;
    if (order == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
      );
    }
    final addr = order.cryptoAddress;
    final qrData = _paymentUri(addr, order.amountUsdt);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(L.sendExactly,
              style: TextStyle(color: AppColors.text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(L.usdtPolygonOnly,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.4)),
            ),
            child: Column(children: [
              Text(L.exactAmount,
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Text('${order.amountUsdt} USDT',
                  style: const TextStyle(color: Color(0xFF00D4FF),
                      fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('carte \$${order.cardValue.toStringAsFixed(0)} · réseau Polygon',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.white,
                  child: QrImageView(data: qrData, size: 150, version: QrVersions.auto),
                ),
              ),
              const SizedBox(height: 12),
              Text('ADRESSE USDT (POLYGON)',
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(addr,
                      style: TextStyle(color: AppColors.textSub, fontSize: 11,
                          fontFamily: 'monospace'),
                      maxLines: 2),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: addr));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Adresse copiée'),
                      duration: Duration(seconds: 2),
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.copy_rounded, color: Color(0xFF00D4FF), size: 18),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Text(
              '⚠ Envoyez uniquement sur le réseau Polygon. Tout envoi sur un autre réseau sera perdu.',
              style: TextStyle(color: Colors.amber.withValues(alpha: 0.9), fontSize: 12),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orange, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          _gradientBtn(
            label: 'J\'ai payé — Vérifier',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
            onTap: () => _checkStatus(),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('ID: ${order.redeemId}',
                style: TextStyle(color: AppColors.textDim, fontSize: 10, fontFamily: 'monospace')),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _cancelPending,
                child: const Text('Nouvelle commande',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fermer',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChecking() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Color(0xFF00D4FF)),
        SizedBox(height: 20),
        Text('Vérification du paiement…', style: TextStyle(color: Colors.white70)),
      ]),
    );
  }

  Widget _buildDone() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0096FF)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.black, size: 36),
          ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
        ),
        const SizedBox(height: 20),
        const Text('Carte prête !',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Votre nouvelle carte VCC Mastercard est activée.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
        const SizedBox(height: 24),
        if (_redeemLink != null)
          _gradientBtn(
            label: 'Voir ma carte',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
            onTap: _openLink,
          ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }

}

// ============================================
// CARD DETAILS SHEET
// ============================================
class _CardDetailsSheet extends StatelessWidget {
  final VccCard card;
  const _CardDetailsSheet({required this.card});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: AppColors.isDark
              ? [const Color(0xFF111827), const Color(0xFF0D1117)]
              : [Colors.white, const Color(0xFFF0F5FF)],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Gradient header strip
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: Column(children: [
              Center(child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2)),
              )),
              const SizedBox(height: 10),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.credit_card_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text('Détails de la carte',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                ],
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).padding.bottom + 24),
            child: Column(children: [
              _GlassDetailCard(
                icon: Icons.numbers_rounded,
                iconColor: const Color(0xFF00D4FF),
                label: 'NUMÉRO DE CARTE',
                value: card.formattedNumber,
                mono: true,
                context: context,
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _GlassDetailCard(
                  icon: Icons.calendar_today_rounded,
                  iconColor: const Color(0xFF8B5CF6),
                  label: 'EXPIRATION',
                  value: card.expiry ?? '—',
                  mono: true,
                  context: context,
                )),
                const SizedBox(width: 10),
                Expanded(child: _GlassDetailCard(
                  icon: Icons.lock_rounded,
                  iconColor: const Color(0xFFEC4899),
                  label: 'CVV',
                  value: card.cvv ?? '•••',
                  mono: true,
                  context: context,
                )),
              ]),
              const SizedBox(height: 10),
              _GlassDetailCard(
                icon: Icons.person_rounded,
                iconColor: const Color(0xFF10B981),
                label: 'TITULAIRE',
                value: card.holderName ?? UserProfile.name,
                mono: false,
                context: context,
              ),
              if (card.redeemLink != null && card.redeemLink!.isNotEmpty) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CardWebViewScreen(
                          url: card.redeemLink!,
                          title: 'Swype — gérer la carte',
                        ),
                      ));
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Ouvrir Swype (solde · renommer)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.shield_outlined, size: 13, color: AppColors.textDim),
                const SizedBox(width: 5),
                Text('Ne partagez jamais ces informations',
                    style: TextStyle(color: AppColors.textDim, fontSize: 11, fontStyle: FontStyle.italic)),
              ]),
            ]),
          ),
        ],
      ),
    );
  }
}

class _GlassDetailCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final bool mono;
  final BuildContext context;
  const _GlassDetailCard({
    required this.icon, required this.iconColor,
    required this.label, required this.value,
    required this.mono, required this.context,
  });

  @override
  Widget build(BuildContext _) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF00D4FF), size: 16),
            const SizedBox(width: 8),
            Text('$label copié !'),
          ]),
          backgroundColor: AppColors.card,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 1),
        ));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: AppColors.isDark ? null : [
            BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: AppColors.textDim, fontSize: 9, letterSpacing: 1.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(value,
                  style: TextStyle(
                      color: AppColors.label,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFamily: mono ? 'monospace' : null,
                      letterSpacing: mono ? 1.2 : 0)),
            ],
          )),
          Icon(Icons.copy_rounded, color: AppColors.textDim, size: 15),
        ]),
      ),
    );
  }
}


// ============================================
// TRANSACTIONS SCREEN
// ============================================
class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Historique',
            style: TextStyle(
                color: AppColors.label, fontWeight: FontWeight.bold)),
      ),
      body: FutureBuilder<List<VccTx>>(
        future: VccTx.loadAll(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFF00D4FF)));
          }
          final txs = snap.data ?? [];
          if (txs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_rounded,
                      color: AppColors.border,
                      size: 72),
                  const SizedBox(height: 16),
                  Text('Aucune transaction',
                      style: TextStyle(
                          color: AppColors.textSub,
                          fontSize: 16)),
                  const SizedBox(height: 6),
                  Text('Activez votre carte pour commencer',
                      style: TextStyle(
                          color: AppColors.textDim,
                          fontSize: 13)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: txs.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: 8),
            itemBuilder: (_, i) => _TxRow(tx: txs[i]),
          );
        },
      ),
    );
  }
}

// ============================================
// PROFILE SCREEN
// ============================================
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
              _gradientBtn(
                label: 'Enregistrer',
                loading: _saving,
                colors: const [
                  Color(0xFF00D4FF), Color(0xFF8B5CF6)
                ],
                onTap: _save,
              ),
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
              const SizedBox(height: 10),
              // — Biométrique
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
                    MaterialPageRoute(builder: (_) => const AgentScreen())),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0xFF00D4FF).withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(14),
                    color: const Color(0xFF00D4FF).withValues(alpha: 0.05),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.shield_outlined,
                          color: Color(0xFF00D4FF), size: 18),
                      const SizedBox(width: 10),
                      Text(L.agentMode,
                          style: const TextStyle(
                              color: Color(0xFF00D4FF),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      title: Text('Réinitialiser la carte',
                          style: TextStyle(color: AppColors.text)),
                      content: Text(
                          'Cette action supprimera toutes les données de ta carte VCC de l\'appareil.',
                          style: TextStyle(color: AppColors.textDim)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Annuler',
                              style: TextStyle(color: Colors.white54)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Supprimer',
                              style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await VccCard.remove();
                    if (mounted) setState(() {});
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(14),
                    color: Colors.redAccent.withValues(alpha: 0.05),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          color: Colors.redAccent, size: 18),
                      SizedBox(width: 10),
                      Text('Réinitialiser ma carte',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ),
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
// AGENT SCREEN
// ============================================
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key});
  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen>
    with SingleTickerProviderStateMixin {
  // PIN lock
  bool _unlocked = false;
  String _pin = '';
  bool _pinError = false;
  String _pinExpected = '1234'; // loaded from AgentPin on initState
  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;

  // Form
  final _phoneCtrl   = TextEditingController();
  final _nameCtrl    = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _customCtrl  = TextEditingController();
  bool _isRecharge   = false;
  double _amount     = 7.0;
  bool _customMode   = false;
  static const _presets = [7.0, 10.0, 20.0, 50.0, 100.0, 200.0, 300.0];

  // State
  bool _loading = false;
  String? _error;
  AgentOrder? _current; // active order being processed
  Timer? _autoPoll;
  bool _pinIsDefault = true;

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _shakeAnim = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -12.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -12.0, end: 12.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 12.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
    ]).animate(_shakeCtrl);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _pinExpected = await AgentPin.get();
    _pinIsDefault = await AgentPin.isDefault();
    final order = await AgentOrder.load();
    if (mounted) {
      setState(() { if (order != null) _current = order; });
      if (order != null) _startAutoPoll();
    }
  }

  @override
  void dispose() {
    _autoPoll?.cancel();
    _shakeCtrl.dispose();
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _customCtrl.dispose();
    super.dispose();
  }

  void _pressDigit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _pinError = false;
    });
    if (_pin.length == 4) {
      Future.delayed(const Duration(milliseconds: 120), _checkPin);
    }
  }

  void _backspace() => setState(() {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
        _pinError = false;
      });

  void _checkPin() {
    if (_pin == _pinExpected) {
      setState(() { _unlocked = true; _pinError = false; });
    } else {
      setState(() { _pin = ''; _pinError = true; });
      _shakeCtrl.forward(from: 0);
    }
  }

  Future<void> _changePinDialog() async {
    final newPinCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Changer le PIN agent',
            style: TextStyle(color: AppColors.text)),
        content: TextField(
          controller: newPinCtrl,
          maxLength: 4,
          keyboardType: TextInputType.number,
          obscureText: true,
          style: TextStyle(color: AppColors.text, letterSpacing: 8),
          decoration: const InputDecoration(
            hintText: '4 chiffres',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enregistrer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AgentPin.set(newPinCtrl.text.trim());
      _pinExpected = newPinCtrl.text.trim();
      _pinIsDefault = await AgentPin.isDefault();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('PIN mis à jour')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: Colors.redAccent));
      }
    }
  }

  void _startAutoPoll() {
    _autoPoll?.cancel();
    _autoPoll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_current != null &&
          _current!.state != AgentOrderState.completed) {
        _checkStatus(silent: true);
      }
    });
  }

  Future<void> _checkStatus({bool silent = false}) async {
    final c = _current;
    if (c == null) return;
    try {
      final s = await PayGateService.checkAgentOrderStatus(c.agentOrderToken);
      final state = switch (s['state']) {
        'completed' => AgentOrderState.completed,
        'paid'      => AgentOrderState.paid,
        _           => AgentOrderState.pending,
      };
      if (state != c.state) {
        final updated = c.copyWith(state: state);
        await updated.save();
        if (mounted) setState(() => _current = updated);
        if (state == AgentOrderState.completed) {
          _autoPoll?.cancel();
        }
      } else if (!silent) {
        if (mounted) setState(() => _error = null); // clear stale error
      }
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _error = e.toString().replaceAll('Exception: ', ''));
      }
    }
  }

  Future<void> _confirm() async {
    final phone = _phoneCtrl.text.trim();
    final name  = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    if (phone.isEmpty || name.isEmpty || email.isEmpty) {
      setState(() => _error = 'Téléphone, nom et email du client requis');
      return;
    }
    if (!RegExp(r'^\+?\d[\d\s\-]{5,}$').hasMatch(phone)) {
      setState(() => _error = 'Numéro invalide (format: +213 555 123 456)');
      return;
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _error = 'Email client invalide');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final order = await PayGateService.createVccOrder(
        amount: _amount,
        holderName: name,
        phone: phone,
        flow: _isRecharge ? 'recharge' : 'activation',
        source: 'agent',
        clientEmail: email,
      );
      final token = order.agentOrderToken;
      if (token == null || token.isEmpty) {
        throw Exception('Reponse backend invalide (token manquant)');
      }
      final agentOrder = AgentOrder(
        agentOrderToken: token,
        phone:           phone,
        holderName:      name,
        amountUsd:       order.cardValue,
        flow:            _isRecharge ? 'recharge' : 'activation',
        cryptoAddress:   order.cryptoAddress,
        amountUsdt:      order.amountUsdt,
        createdAt:       DateTime.now(),
        claimCode:       order.claimCode,
      );
      await agentOrder.save();
      if (!mounted) return;
      setState(() { _current = agentOrder; _loading = false; });
      _startAutoPoll();
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _newOperation() async {
    _autoPoll?.cancel();
    await AgentOrder.clear();
    if (mounted) {
      setState(() {
        _current = null;
        _error = null;
        _phoneCtrl.clear();
        _nameCtrl.clear();
        _emailCtrl.clear();
        _customCtrl.clear();
        _isRecharge = false;
        _customMode = false;
        _amount = 7.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.label,
        elevation: 0,
        title: const Text('Mode Agent',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (_unlocked)
            IconButton(
              tooltip: 'Changer le PIN',
              icon: const Icon(Icons.password_rounded),
              onPressed: _changePinDialog,
            ),
        ],
      ),
      body: _unlocked ? _buildPanel() : _buildPinLock(),
    );
  }

  // ── PIN LOCK ──────────────────────────────────────────────────
  Widget _buildPinLock() {
    return SafeArea(
      child: Column(children: [
        const SizedBox(height: 40),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF00D4FF).withValues(alpha: 0.1),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF00D4FF).withValues(alpha: 0.3),
                  blurRadius: 24),
            ],
          ),
          child: const Icon(Icons.shield_rounded,
              color: Color(0xFF00D4FF), size: 40),
        ),
        const SizedBox(height: 24),
        Text('Code Agent',
            style: TextStyle(
                color: AppColors.label,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Entrez votre code à 4 chiffres',
            style: TextStyle(color: AppColors.hint, fontSize: 13)),
        const SizedBox(height: 36),
        AnimatedBuilder(
          animation: _shakeAnim,
          builder: (_, child) =>
              Transform.translate(offset: Offset(_shakeAnim.value, 0), child: child),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (i) {
              final filled = i < _pin.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 10),
                width: 18, height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _pinError
                      ? Colors.redAccent
                      : filled
                          ? const Color(0xFF00D4FF)
                          : Colors.white12,
                  boxShadow: filled && !_pinError
                      ? [BoxShadow(
                          color: const Color(0xFF00D4FF).withValues(alpha: 0.5),
                          blurRadius: 8)]
                      : null,
                ),
              );
            }),
          ),
        ),
        if (_pinError) ...[
          const SizedBox(height: 12),
          const Text('Code incorrect',
              style: TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],
        const Spacer(),
        // Numpad
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
          child: Column(
            children: [
              for (final row in [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
                ['', '0', '⌫'],
              ])
                Row(
                  children: row.map((d) {
                    if (d.isEmpty) return const Expanded(child: SizedBox());
                    return Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            d == '⌫' ? _backspace() : _pressDigit(d),
                        child: Container(
                          margin: const EdgeInsets.all(6),
                          height: 64,
                          decoration: BoxDecoration(
                            color: d == '⌫'
                                ? Colors.transparent
                                : AppColors.card,
                            borderRadius: BorderRadius.circular(14),
                            border: d == '⌫'
                                ? null
                                : Border.all(
                                    color: Colors.white.withValues(alpha: 0.06)),
                          ),
                          child: Center(
                            child: d == '⌫'
                                ? const Icon(Icons.backspace_outlined,
                                    color: Colors.white54, size: 22)
                                : Text(d,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w500)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── AGENT PANEL ───────────────────────────────────────────────
  Widget _buildPanel() {
    return Column(children: [
      if (_pinIsDefault)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.redAccent.withValues(alpha: 0.12),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.redAccent, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'PIN par défaut (1234) — changez-le maintenant.',
                style: TextStyle(color: Colors.redAccent.withValues(alpha: 0.95), fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: _changePinDialog,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10)),
              child: const Text('Changer',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      Expanded(
        child: _current != null ? _buildOrderStatus() : _buildForm(),
      ),
    ]);
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          // Type toggle
          Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              _typeBtn('Activation', !_isRecharge, () {
                setState(() { _isRecharge = false; _amount = 7.0; });
              }),
              _typeBtn('Rechargement', _isRecharge, () {
                setState(() { _isRecharge = true; _amount = 20.0; });
              }),
            ]),
          ),
          const SizedBox(height: 24),
          const _FieldLabel('Téléphone du client *'),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '+213 XXX XXX XXX',
              hintStyle: TextStyle(color: AppColors.hint),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Color(0xFF00D4FF))),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('Nom complet du client *'),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Prénom Nom',
              hintStyle: TextStyle(color: AppColors.hint),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Color(0xFF00D4FF))),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('Email du client *'),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'client@email.com',
              hintStyle: TextStyle(color: AppColors.hint),
              helperText: 'Doit être l\'email que le client a vérifié dans son app Tchipa.',
              helperStyle: TextStyle(color: AppColors.textDim, fontSize: 11),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Color(0xFF00D4FF))),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
            ),
          ),
          if (_isRecharge) ...[
            const SizedBox(height: 20),
            const _FieldLabel('Montant (USD)'),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                ..._presets.where((p) => p != 7.0).map((p) {
                  final sel = !_customMode && _amount == p;
                  return GestureDetector(
                    onTap: () => setState(() { _amount = p; _customMode = false; _customCtrl.clear(); }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: sel ? const Color(0xFF00D4FF) : AppColors.card,
                        border: sel ? null : Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Text('\$${p.toStringAsFixed(0)}',
                          style: TextStyle(
                              color: sel ? Colors.black : Colors.white70,
                              fontWeight: FontWeight.w600)),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: () => setState(() { _customMode = true; }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _customMode ? const Color(0xFF8B5CF6) : AppColors.card,
                      border: _customMode ? null : Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Text('Autre',
                        style: TextStyle(
                            color: _customMode ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
            if (_customMode) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _customCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(color: AppColors.inputFg),
                onChanged: (v) {
                  final parsed = double.tryParse(v);
                  if (parsed != null && parsed >= 5) setState(() => _amount = parsed);
                },
                decoration: InputDecoration(
                  hintText: 'Montant libre (min 5\$)',
                  hintStyle: TextStyle(color: Colors.white38),
                  prefixText: '\$ ',
                  prefixStyle: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: AppColors.card,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 2)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: const Color(0xFF8B5CF6).withValues(alpha: 0.5))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ],
          ],
          const SizedBox(height: 24),
          // Summary box — shown only for recharge (no fee display for activation)
          if (_isRecharge)
          Container(
            padding: const EdgeInsets.symmetric(
                vertical: 14, horizontal: 20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFF00D4FF).withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Montant à encaisser',
                    style: TextStyle(
                        color: AppColors.textSub,
                        fontSize: 13)),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('\$${_amount.toStringAsFixed(0)} USD',
                      style: const TextStyle(
                          color: Color(0xFF00D4FF),
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  Text(
                      '${(_amount * kExchangeRate).toStringAsFixed(0)} DA',
                      style: TextStyle(
                          color: AppColors.textDim,
                          fontSize: 11)),
                ]),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 13)),
            ),
          ],
          const SizedBox(height: 24),
          _gradientBtn(
            label: _isRecharge
                ? 'Confirmer le rechargement'
                : 'Activer la carte',
            loading: _loading,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _confirm,
          ),
        ],
      ),
    );
  }

  Widget _typeBtn(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: active
                ? const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)])
                : null,
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: active ? Colors.black : AppColors.sublabel,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
      ),
    );
  }

  Widget _buildOrderStatus() {
    final o = _current!;
    final isCompleted = o.state == AgentOrderState.completed;
    final isPaid      = o.state == AgentOrderState.paid;

    // Icon + headline reflect the actual lifecycle stage so the agent
    // can never confuse "order created" with "payment confirmed".
    final IconData icon;
    final Color   iconColor;
    final String  headline;
    final String  subline;
    if (isCompleted) {
      icon = Icons.check_circle_rounded;
      iconColor = const Color(0xFF22D3A1);
      headline = 'Carte livrée au client';
      subline = 'Le client ${o.holderName} (${o.phone}) verra la carte apparaître dans son app Tchipa.';
    } else if (isPaid) {
      icon = Icons.hourglass_bottom_rounded;
      iconColor = const Color(0xFFFFB020);
      headline = 'Paiement reçu — carte en émission';
      subline = 'PayGate génère la carte (~30–60s). On vérifie automatiquement.';
    } else {
      icon = Icons.payments_rounded;
      iconColor = const Color(0xFF00D4FF);
      headline = 'En attente du paiement USDT';
      subline = 'Envoyez exactement le montant ci-dessous au wallet VPS (Polygon). On vérifie automatiquement.';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 48),
            ),
          ),
          const SizedBox(height: 16),
          Text(headline,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(subline,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),

          // Client info — always visible (no card secrets here, just routing info)
          _infoCard('Client', '${o.holderName}  ·  ${o.phone}', Icons.person_outline_rounded),
          const SizedBox(height: 12),
          _infoCard('Type · Montant',
              '${o.flow == 'recharge' ? 'Rechargement' : 'Activation'}  ·  \$${o.amountUsd.toStringAsFixed(0)}',
              Icons.tune_rounded),
          const SizedBox(height: 12),

          // Claim code — to be relayed to the client out-of-band (Telegram).
          // Without it the user's app cannot unlock the redeem link, so
          // someone who only knows the phone number can't steal the card.
          if (o.claimCode != null && o.claimCode!.isNotEmpty) ...[
            _ClaimCodeCard(code: o.claimCode!),
            const SizedBox(height: 12),
          ],

          // Payment instructions — hide once paid
          if (!isPaid && !isCompleted) ...[
            _infoCard('Montant USDT (Polygon)', '${o.amountUsdt} USDT', Icons.toll_rounded),
            const SizedBox(height: 12),
            _infoCard('Envoyer USDT ici (Polygon)', o.cryptoAddress, Icons.account_balance_wallet_rounded),
            const SizedBox(height: 12),
          ],

          // Référence courte (8 premiers chars du token) — utile pour le SAV
          // sans jamais exposer le redeem_id sous-jacent au PayGate.
          _infoCard(
            'Référence',
            o.agentOrderToken.isEmpty
                ? '—'
                : o.agentOrderToken.substring(0, 8).toUpperCase(),
            Icons.tag_rounded,
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],

          const SizedBox(height: 24),
          if (!isCompleted)
            _gradientBtn(
              label: 'Vérifier le paiement',
              loading: false,
              colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
              onTap: () => _checkStatus(),
            ),
          if (isCompleted)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF22D3A1).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF22D3A1).withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.lock_outline_rounded,
                    color: Color(0xFF22D3A1), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Les détails de la carte (numéro, CVV, expiration) ne sont jamais visibles côté agent. Ils n\'apparaissent que sur l\'app du client.',
                    style: TextStyle(color: AppColors.textSub, fontSize: 12),
                  ),
                ),
              ]),
            ),
          const SizedBox(height: 12),
          _gradientBtn(
            label: 'Nouvelle opération',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _newOperation,
          ),
        ],
      ),
    );
  }

  Widget _infoCard(String label, String value, IconData icon) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$label copié'),
          duration: const Duration(seconds: 1),
          backgroundColor: AppColors.card,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: const Color(0xFF00D4FF).withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: const Color(0xFF00D4FF), size: 14),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      letterSpacing: 1.2)),
              const Spacer(),
              const Icon(Icons.copy_rounded,
                  color: Colors.white24, size: 14),
            ]),
            const SizedBox(height: 8),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    letterSpacing: 1.5)),
          ],
        ),
      ),
    );
  }

}

// Prominent claim-code card shown in the agent panel. The agent must read
// this code and send it to the client via Telegram/SMS — the client's app
// asks for it before unlocking the redeem link.
class _ClaimCodeCard extends StatelessWidget {
  final String code;
  const _ClaimCodeCard({required this.code});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: code));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Code copié — envoyez-le au client'),
          duration: const Duration(seconds: 2),
          backgroundColor: AppColors.card,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFFFB020).withValues(alpha: 0.18),
              const Color(0xFFFF7A00).withValues(alpha: 0.08),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: const Color(0xFFFFB020).withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.vpn_key_rounded,
                  color: Color(0xFFFFB020), size: 16),
              const SizedBox(width: 8),
              const Text('CODE DE DÉVERROUILLAGE',
                  style: TextStyle(
                      color: Color(0xFFFFB020),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2)),
              const Spacer(),
              const Icon(Icons.copy_rounded,
                  color: Color(0xFFFFB020), size: 16),
            ]),
            const SizedBox(height: 10),
            Center(
              child: Text(code,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      letterSpacing: 10)),
            ),
            const SizedBox(height: 8),
            Text(
              'Envoyez ce code au client par Telegram. Sans lui, son app ne pourra pas récupérer la carte.',
              style: TextStyle(color: AppColors.textSub, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================
// SHARED HELPERS
// ============================================

Widget _gradientBtn({
  required String label,
  required bool loading,
  required List<Color> colors,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: loading ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(16),
      ),
      child: loading
          ? const Center(
              child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.black),
              ),
            )
          : Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)),
    ),
  );
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
// CARD WEBVIEW SCREEN
// ============================================
class CardWebViewScreen extends StatefulWidget {
  final String url;
  final String title;
  final void Function(String? cardNumber, String? cvv, String? expiry)? onCardData;
  const CardWebViewScreen({super.key, required this.url, this.title = 'Ma carte', this.onCardData});

  @override
  State<CardWebViewScreen> createState() => _CardWebViewScreenState();
}

class _CardWebViewScreenState extends State<CardWebViewScreen> {
  late final WebViewController _controller;
  bool _extracted = false;
  bool _showFallback = false; // true only if extraction failed after timeout

  // Robust card-data extraction. Swype's reveal page is a React SPA — the
  // card data appears in the DOM only after async hydration finishes, which
  // can be 2-8s after onPageFinished depending on network. So we retry on
  // a MutationObserver-flavoured schedule rather than fire-and-forget.
  //
  // Strategy stack, each attempt:
  //   1. <input>/<textarea> values — Swype renders the card in masked
  //      inputs the user can "reveal"/"copy"; .value carries the data even
  //      when textContent is empty.
  //   2. Leaf elements with short numeric text — divs/spans holding the PAN
  //      after the user clicks "show".
  //   3. data-* attributes & aria-labels — copy-to-clipboard buttons often
  //      stash the value here.
  //   4. Whole-body regex sweep — last resort if the above selectors miss.
  static const _kExtractJs = r'''
(function(){
  if (window.__tchipaExtractStarted) return; window.__tchipaExtractStarted = true;
  var attempts = 0;
  var MAX_ATTEMPTS = 12;        // ~18s total at 1500ms apart
  var INTERVAL_MS = 1500;
  function looksLikePan(s){ var d=String(s||'').replace(/[\s-]/g,''); return /^\d{15,19}$/.test(d) ? d : null; }
  function looksLikeCvv(s){ var d=String(s||'').replace(/\D/g,''); return /^\d{3,4}$/.test(d) ? d : null; }
  function looksLikeExp(s){ var t=String(s||'').trim(); return /\b(0[1-9]|1[0-2])[\/\-](\d{2,4})\b/.test(t) ? t.match(/\b(0[1-9]|1[0-2])[\/\-](\d{2,4})\b/)[0] : null; }
  function collect(){
    var hits = { n:null, c:null, e:null };
    // --- inputs / textareas (value) ---
    var inputs = document.querySelectorAll('input,textarea');
    for (var i = 0; i < inputs.length; i++) {
      var v = inputs[i].value || inputs[i].getAttribute('value') || '';
      if (!v) continue;
      if (!hits.n) { var n = looksLikePan(v); if (n) hits.n = n; }
      if (!hits.c) { var c = looksLikeCvv(v); if (c) hits.c = c; }
      if (!hits.e) { var e = looksLikeExp(v); if (e) hits.e = e; }
    }
    // --- data-clipboard-text / data-value / aria-label on any element ---
    if (!hits.n || !hits.c || !hits.e) {
      var withAttrs = document.querySelectorAll('[data-clipboard-text],[data-value],[data-copy],[aria-label]');
      for (var j = 0; j < withAttrs.length; j++) {
        var el = withAttrs[j];
        var v2 = el.getAttribute('data-clipboard-text') || el.getAttribute('data-value') ||
                 el.getAttribute('data-copy') || el.getAttribute('aria-label') || '';
        if (!v2) continue;
        if (!hits.n) { var n2 = looksLikePan(v2); if (n2) hits.n = n2; }
        if (!hits.c) { var c2 = looksLikeCvv(v2); if (c2) hits.c = c2; }
        if (!hits.e) { var e2 = looksLikeExp(v2); if (e2) hits.e = e2; }
      }
    }
    // --- leaf elements (short text only) ---
    if (!hits.n || !hits.c || !hits.e) {
      var all = document.querySelectorAll('*');
      for (var k = 0; k < all.length && (!hits.n || !hits.c || !hits.e); k++) {
        var elx = all[k];
        if (elx.children && elx.children.length > 0) continue;
        var t = (elx.textContent || '').replace(/\s+/g, ' ').trim();
        if (!t || t.length > 30) continue;
        if (!hits.n) { var nn = looksLikePan(t); if (nn) hits.n = nn; }
        if (!hits.c) { var cc = looksLikeCvv(t); if (cc) hits.c = cc; }
        if (!hits.e) { var ee = looksLikeExp(t); if (ee) hits.e = ee; }
      }
    }
    // --- whole-body regex (handles concatenated text nodes) ---
    if (!hits.n || !hits.c || !hits.e) {
      var b = document.body ? document.body.innerText : '';
      if (!hits.n) { var m1 = b.match(/\b(\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4})\b/); if (m1) hits.n = m1[1].replace(/[\s-]/g,''); }
      if (!hits.c) { var m2 = b.match(/CVV[^\d]{0,10}(\d{3,4})/i)||b.match(/CVC[^\d]{0,10}(\d{3,4})/i)||b.match(/Security[^\d]{0,15}(\d{3,4})/i); if (m2) hits.c = m2[1]; }
      if (!hits.e) { var m3 = b.match(/\b(0[1-9]|1[0-2])[\/\-](\d{2,4})\b/); if (m3) hits.e = m3[0]; }
    }
    return hits;
  }
  function tick(){
    attempts++;
    try {
      var r = collect();
      if (r.n) { // PAN is the gate — without it the whole row is useless
        TchipaCard.postMessage(JSON.stringify({cardNumber:r.n, cvv:r.c, expiry:r.e}));
        return;
      }
    } catch(err){ /* swallow per-tick; keep retrying */ }
    if (attempts < MAX_ATTEMPTS) {
      setTimeout(tick, INTERVAL_MS);
    } else {
      // Final diagnostic so we know what the page actually contained.
      try {
        var snippet = (document.body ? document.body.innerText : '').slice(0, 400);
        TchipaCard.postMessage(JSON.stringify({error:'extraction_timeout', snippet:snippet}));
      } catch(_){ TchipaCard.postMessage(JSON.stringify({error:'extraction_timeout'})); }
    }
  }
  setTimeout(tick, 800); // small head start so the SPA can render the first frame
})();
''';

  // Web (iPhone PWA): webview_flutter has no web implementation and PayGate's
  // reveal page can't be embedded/scraped cross-origin anyway. Open the redeem
  // link in a new browser tab instead; manual entry stays available.
  Future<void> _openExternally() async {
    final uri = Uri.parse(widget.url);
    await launchUrl(uri, webOnlyWindowName: '_blank',
        mode: LaunchMode.externalApplication);
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return; // no WebViewController on web — see _buildWeb()
    // Always reveal the underlying WebView after 8s so the user can read +
    // copy the numbers manually if our JS scrape fails. Total extraction
    // budget is ~18s (12 retries × 1.5s); after that we surface a snackbar
    // telling them to read the card directly from the page.
    Future.delayed(const Duration(seconds: 8), () {
      if (!_extracted && mounted) setState(() => _showFallback = true);
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.bg)
      ..addJavaScriptChannel('TchipaCard', onMessageReceived: (msg) {
        if (_extracted || widget.onCardData == null) return;
        try {
          final data = jsonDecode(msg.message) as Map<String, dynamic>;
          if (data['error'] != null) {
            debugPrint('[CardWebView] extract error: ${data['error']} snippet=${data['snippet']?.toString() ?? ''}');
            // Fire-and-forget POST the snippet to a debug endpoint so we can
            // iterate on selectors without needing adb logcat from the user.
            final snippet = data['snippet']?.toString();
            if (snippet != null && snippet.isNotEmpty) {
              http.post(
                Uri.parse('$kVpsBase/debug/webview-snippet'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'snippet': snippet, 'url': widget.url}),
              ).timeout(const Duration(seconds: 5)).catchError((_) => http.Response('', 0));
            }
            if (mounted) {
              setState(() => _showFallback = true);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: const Text('Lecture auto échouée. Tape ✏️ en haut à droite pour saisir manuellement.'),
                backgroundColor: Colors.orange.shade800,
                duration: const Duration(seconds: 8),
              ));
            }
            return;
          }
          final number = data['cardNumber'] as String?;
          final cvv = data['cvv'] as String?;
          final expiry = data['expiry'] as String?;
          if (number != null && number.length >= 15) {
            _extracted = true;
            widget.onCardData!(number, cvv, expiry);
          }
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (widget.onCardData != null) {
            _controller.runJavaScript(_kExtractJs);
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _manualEntryDialog() async {
    final numCtrl = TextEditingController();
    final cvvCtrl = TextEditingController();
    final expCtrl = TextEditingController();
    String? errorMsg;
    bool submitted = false;
    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(builder: (dlgCtx, setDlg) {
        void submit() {
          final n = numCtrl.text.replaceAll(RegExp(r'[\s-]'), '');
          final c = cvvCtrl.text.trim();
          final e = expCtrl.text.trim();
          if (!RegExp(r'^\d{15,19}$').hasMatch(n)) {
            setDlg(() => errorMsg = 'Numéro invalide (15-19 chiffres)');
            return;
          }
          if (!RegExp(r'^\d{3,4}$').hasMatch(c)) {
            setDlg(() => errorMsg = 'CVV invalide (3-4 chiffres)');
            return;
          }
          if (!RegExp(r'^(0[1-9]|1[0-2])[\/\-]\d{2,4}$').hasMatch(e)) {
            setDlg(() => errorMsg = 'Expiration: MM/AA (ex 04/28)');
            return;
          }
          submitted = true;
          Navigator.of(dlgCtx).pop();
          if (!_extracted && widget.onCardData != null) {
            _extracted = true;
            widget.onCardData!(n, c, e);
          }
        }
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Saisie manuelle', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                'Recopie les valeurs depuis l\'écran Swype derrière ce dialog.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: numCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', letterSpacing: 2),
                decoration: const InputDecoration(labelText: 'Numéro carte (16 chiffres)'),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: expCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'MM/AA'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: cvvCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'CVV'),
                  ),
                ),
              ]),
              if (errorMsg != null) ...[
                const SizedBox(height: 8),
                Text(errorMsg!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dlgCtx).pop(), child: const Text('Annuler')),
            ElevatedButton(onPressed: submit, child: const Text('Enregistrer')),
          ],
        );
      }),
    );
    if (submitted && mounted) Navigator.of(context).pop();
  }

  // iPhone PWA build: no embedded WebView; the user opens the card in a new
  // tab and can type the numbers manually if needed.
  Widget _buildWeb(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.title,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.credit_card_rounded,
                  color: Color(0xFF00D4FF), size: 64),
              const SizedBox(height: 24),
              const Text('Votre carte est prête',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                'Appuyez ci-dessous pour ouvrir votre carte dans un onglet sécurisé.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.sublabel, fontSize: 14),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _openExternally,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Ouvrir ma carte'),
                ),
              ),
              if (widget.onCardData != null) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _manualEntryDialog,
                  child: const Text('Saisir les infos manuellement'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return _buildWeb(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.title,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          if (widget.onCardData != null)
            IconButton(
              tooltip: 'Saisir manuellement',
              icon: const Icon(Icons.edit_note_rounded, color: Colors.white),
              onPressed: _manualEntryDialog,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white54),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(children: [
        WebViewWidget(controller: _controller),
        // Hide the PayGate page behind our loading screen until extraction succeeds.
        // Only removed (_showFallback) if JS extraction fails after 6s.
        if (!_showFallback)
          Container(
            color: AppColors.bg,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 56, height: 56,
                    child: CircularProgressIndicator(
                      color: Color(0xFF00D4FF),
                      strokeWidth: 2.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Récupération de votre carte…',
                      style: TextStyle(color: AppColors.sublabel, fontSize: 15)),
                  const SizedBox(height: 8),
                  Text('Quelques secondes',
                      style: TextStyle(color: AppColors.hint, fontSize: 13)),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}
