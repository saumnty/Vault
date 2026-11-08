import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AddItemSheet extends StatefulWidget {
  final Function(String title, String content) onSave;

  const AddItemSheet({super.key, required this.onSave});

  @override
  State<AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<AddItemSheet> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0xFF2C2C2E),
        middle: const Text(
          'Nuevo Elemento',
          style: TextStyle(color: CupertinoColors.white),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Text('Cancelar', style: TextStyle(color: CupertinoColors.systemRed)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.bold, color: CupertinoColors.systemIndigo)),
          onPressed: () {
            final title = _titleController.text.trim();
            final content = _contentController.text.trim();
            if (title.isNotEmpty && content.isNotEmpty) {
              widget.onSave(title, content);
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'DETALLES DE LA CREDENCIAL',
                style: TextStyle(
                  color: CupertinoColors.systemGrey,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    CupertinoTextField(
                      controller: _titleController,
                      placeholder: 'Título (ej. Banco, Correo)',
                      placeholderStyle: const TextStyle(color: CupertinoColors.systemGrey),
                      style: const TextStyle(color: CupertinoColors.white),
                      padding: const EdgeInsets.all(12),
                      decoration: null,
                    ),
                    Container(height: 0.5, color: const Color(0xFF38383A), margin: const EdgeInsets.only(left: 12)),
                    CupertinoTextField(
                      controller: _contentController,
                      placeholder: 'Contraseña o Nota Sensible',
                      placeholderStyle: const TextStyle(color: CupertinoColors.systemGrey),
                      style: const TextStyle(color: CupertinoColors.white),
                      padding: const EdgeInsets.all(12),
                      obscureText: true,
                      decoration: null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}