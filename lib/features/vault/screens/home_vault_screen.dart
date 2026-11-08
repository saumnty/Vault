import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'add_item_sheet.dart';
import '../services/vault_repository.dart';
import '../../../core/security/session_manager.dart';

class HomeVaultScreen extends StatefulWidget {
  const HomeVaultScreen({super.key});

  @override
  State<HomeVaultScreen> createState() => _HomeVaultScreenState();
}

class _HomeVaultScreenState extends State<HomeVaultScreen> {
  final VaultRepository _vaultRepository = VaultRepository();
  List < Map < String, dynamic > > _items = [];

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final items = await _vaultRepository.getAllItemsRaw();
    setState(() {
      _items = items;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF000000),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0xFF1C1C1E).withValues(alpha:0.8),
        middle: const Text(
          'Vault',
          style: TextStyle(color: CupertinoColors.white, fontWeight: FontWeight.w600),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Icon(CupertinoIcons.add, color: CupertinoColors.systemIndigo),
          onPressed: () {
            Navigator.of(context).push(
              CupertinoPageRoute(
                fullscreenDialog: true,
                builder: (context) => AddItemSheet(
                  onSave: (title, content) async {
                    final key = SessionManager.masterKey;
                    if (key != null) {
                      await _vaultRepository.saveItem(title, content, key);
                      await _loadItems();
                    }
                  },
                ),
              ),
            );
          },
        ),
      ),
      child: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16.0),
          children: [
            CupertinoSearchTextField(
              placeholder: 'Buscar en la bóveda',
              style: const TextStyle(color: CupertinoColors.white),
              backgroundColor: const Color(0xFF1C1C1E),
              prefixIcon: const Icon(CupertinoIcons.search, color: CupertinoColors.systemGrey),
              suffixIcon: const Icon(CupertinoIcons.xmark_circle_fill, color: CupertinoColors.systemGrey),
              onChanged: (value) {},
            ),
            const SizedBox(height: 24),
            const Text(
              'ELEMENTOS GUARDADOS',
              style: TextStyle(
                color: CupertinoColors.systemGrey,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20.0),
                      child: Center(
                        child: Text(
                          'No hay elementos cifrados aún',
                          style: TextStyle(color: CupertinoColors.systemGrey),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _items.length,
                      separatorBuilder: (context, index) => Container(
                        height: 0.5,
                        color: const Color(0xFF38383A),
                        margin: const EdgeInsets.only(left: 16),
                      ),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          onPressed: () {},
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: CupertinoColors.systemOrange,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(CupertinoIcons.lock_fill, color: CupertinoColors.white, size: 20),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  item['title'] ?? '',
                                  style: const TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const Icon(
                                CupertinoIcons.chevron_right,
                                color: CupertinoColors.systemGrey3,
                                size: 16,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}