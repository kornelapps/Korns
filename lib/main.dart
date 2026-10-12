import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

// Motor de imagenes. Si algun dia cambia, solo se edita esto.
const String kEndpoint = 'https://image.pollinations.ai/prompt/';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Kornels Imagenes',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF6C4DFF),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const Home(),
      );
}

class Item {
  final int id;
  final String prompt, style, path;
  Item(this.id, this.prompt, this.style, this.path);
}

class Db {
  static Database? _db;
  static Future<Database> get db async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'imagenes.db'),
        version: 1,
        onCreate: (d, v) => d.execute(
            'CREATE TABLE img(id INTEGER PRIMARY KEY AUTOINCREMENT, prompt TEXT, style TEXT, path TEXT)'),
      );
  static Future<void> add(String prompt, String style, String path) async =>
      (await db).insert('img', {'prompt': prompt, 'style': style, 'path': path});
  static Future<List<Item>> all() async {
    final r = await (await db).query('img', orderBy: 'id DESC');
    return r
        .map((m) => Item(m['id'] as int, m['prompt'] as String,
            m['style'] as String, m['path'] as String))
        .toList();
  }

  static Future<void> remove(Item i) async {
    await (await db).delete('img', where: 'id=?', whereArgs: [i.id]);
    final f = File(i.path);
    if (await f.exists()) await f.delete();
  }
}

const styles = <String, String>{
  'Ninguno': '',
  'Realista': 'photorealistic, ultra detailed, 8k, natural lighting',
  'Anime': 'anime style, vibrant colors, detailed',
  'Arte digital': 'digital art, concept art, highly detailed',
  'Pintura al oleo': 'oil painting, textured brush strokes',
  '3D': '3d render, octane render, soft lighting',
  'Pixel art': 'pixel art, 16-bit, retro game',
};

const sizes = <String, List<int>>{
  'Cuadrado 1:1': [1024, 1024],
  'Vertical 9:16': [768, 1344],
  'Horizontal 16:9': [1344, 768],
  'Retrato 3:4': [896, 1152],
};

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: IndexedStack(index: tab, children: [
          Generator(onSaved: () => setState(() {})),
          Gallery(key: ValueKey(tab)),
        ])),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'Crear'),
            NavigationDestination(
                icon: Icon(Icons.photo_library), label: 'Galeria'),
          ],
        ),
      );
}

class Generator extends StatefulWidget {
  final VoidCallback onSaved;
  const Generator({super.key, required this.onSaved});
  @override
  State<Generator> createState() => _GeneratorState();
}

class _GeneratorState extends State<Generator> {
  final ctrl = TextEditingController();
  String style = 'Ninguno', size = 'Cuadrado 1:1';
  bool loading = false;
  String? error;
  File? result;

  Future<void> generate() async {
    final prompt = ctrl.text.trim();
    if (prompt.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final full =
          styles[style]!.isEmpty ? prompt : '$prompt, ${styles[style]}';
      final wh = sizes[size]!;
      final seed = Random().nextInt(1 << 30);
      final uri = Uri.parse(
          '$kEndpoint${Uri.encodeComponent(full)}?width=${wh[0]}&height=${wh[1]}&seed=$seed&model=flux&nologo=true');
      final r = await http.get(uri).timeout(const Duration(seconds: 120));
      if (r.statusCode != 200 ||
          !(r.headers['content-type'] ?? '').startsWith('image')) {
        throw 'El servidor respondio ${r.statusCode}. Espera unos segundos e intenta de nuevo.';
      }
      final dir = Directory(
          p.join((await getApplicationDocumentsDirectory()).path, 'imagenes'));
      await dir.create(recursive: true);
      final f = File(p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}.jpg'));
      await f.writeAsBytes(r.bodyBytes);
      await Db.add(prompt, style, f.path);
      widget.onSaved();
      setState(() => result = f);
    } catch (e) {
      setState(() => error = 'No se pudo generar: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Kornels Imagenes',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Describe la imagen que quieres...'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: DropdownButtonFormField<String>(
              value: style,
              decoration: const InputDecoration(
                  labelText: 'Estilo', border: OutlineInputBorder()),
              items: styles.keys
                  .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                  .toList(),
              onChanged: (v) => setState(() => style = v!),
            )),
            const SizedBox(width: 8),
            Expanded(
                child: DropdownButtonFormField<String>(
              value: size,
              decoration: const InputDecoration(
                  labelText: 'Tamano', border: OutlineInputBorder()),
              items: sizes.keys
                  .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                  .toList(),
              onChanged: (v) => setState(() => size = v!),
            )),
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: loading ? null : generate,
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(loading ? 'Generando...' : 'Generar'),
          ),
          if (error != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (result != null) ...[
            const SizedBox(height: 16),
            ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(result!)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Share.shareXFiles([XFile(result!.path)],
                  text: 'Hecho con Kornels Imagenes'),
              icon: const Icon(Icons.share),
              label: const Text('Compartir / guardar'),
            ),
          ],
        ],
      );
}

class Gallery extends StatelessWidget {
  const Gallery({super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Item>>(
        future: Db.all(),
        builder: (c, s) {
          final items = s.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('Aun no has generado imagenes'));
          }
          return GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, mainAxisSpacing: 8, crossAxisSpacing: 8),
            itemCount: items.length,
            itemBuilder: (c, i) => GestureDetector(
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => Detail(items[i]))),
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(items[i].path), fit: BoxFit.cover)),
            ),
          );
        },
      );
}

class Detail extends StatelessWidget {
  final Item item;
  const Detail(this.item, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(item.style == 'Ninguno' ? 'Imagen' : item.style)),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          Image.file(File(item.path)),
          const SizedBox(height: 12),
          Text(item.prompt),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
              onPressed: () => Share.shareXFiles([XFile(item.path)]),
              icon: const Icon(Icons.share),
              label: const Text('Compartir / guardar'),
            )),
            const SizedBox(width: 8),
            IconButton.outlined(
              onPressed: () async {
                await Db.remove(item);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.delete),
            ),
          ]),
        ]),
      );
}
