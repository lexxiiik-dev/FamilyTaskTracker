import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// На защищённом адресе — обычный API буфера обмена; по http он недоступен,
/// там текст копируется через временное поле ввода.
Future<bool> copyText(String text) async {
  if (web.window.isSecureContext) {
    try {
      await web.window.navigator.clipboard.writeText(text).toDart;
      return true;
    } catch (_) {}
  }
  final ta = web.document.createElement('textarea') as web.HTMLTextAreaElement;
  ta.value = text;
  ta.setAttribute('readonly', '');
  ta.style
    ..position = 'fixed'
    ..left = '-9999px'
    ..top = '0'
    ..opacity = '0';
  web.document.body!.append(ta);
  final active = web.document.activeElement;
  var ok = false;
  try {
    ta.focus();
    ta.select();
    ta.setSelectionRange(0, text.length);
    ok = web.document.execCommand('copy');
  } catch (_) {}
  ta.remove();
  if (active != null && active.isA<web.HTMLElement>()) (active as web.HTMLElement).focus();
  return ok;
}
