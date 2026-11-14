import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

class ItemDetailSheet extends StatelessWidget {
  final String title;
  final String decryptedContent;

  const ItemDetailSheet({
    super.key,
    required this.title,
    required this.decryptedContent,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0xFF2C2C2E),
        middle: const Text(
          'Detalle Seguro',
          style: TextStyle(color: CupertinoColors.white),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Text('Cerrar', style: TextStyle(fontWeight: FontWeight.bold, color: CupertinoColors.systemIndigo)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'CONTENIDO DESCIFRADO',
                style: TextStyle(
                  color: CupertinoColors.systemGrey,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  decryptedContent,
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 18,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  color: CupertinoColors.systemIndigo,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.doc_on_clipboard_fill, size: 20),
                      SizedBox(width: 8),
                      Text('Copiar al portapapeles'),
                    ],
                  ),
                  onPressed: () {
                    // Copia al portapapeles de iOS/Android
                    Clipboard.setData(ClipboardData(text: decryptedContent));
                    Navigator.of(context).pop();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}