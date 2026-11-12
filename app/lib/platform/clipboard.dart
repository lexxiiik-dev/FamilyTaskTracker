// Копирование текста в буфер обмена. В браузере у страницы по http нет доступа к буферу
// через обычный API, поэтому у веб-версии своя реализация.
export 'clipboard_io.dart' if (dart.library.js_interop) 'clipboard_web.dart';
