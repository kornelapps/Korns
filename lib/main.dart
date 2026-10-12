import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

// Motor de imagenes. Si algun dia cambia, solo se edita esto.
const String kEndpoint = 'https://image.pollinations.ai/prompt/';

const _canal = MethodChannel('kornels/nativo');

// ---------------- Motor offline (stable-diffusion.cpp) ----------------

class Modelo {
  final String id, nombre, archivo;
  final int mb;
  const Modelo(this.id, this.nombre, this.archivo, this.mb);
  String get url =>
      'https://huggingface.co/second-state/stable-diffusion-v1-5-GGUF/resolve/main/$archivo';
}

const modelos = <Modelo>[
  Modelo('q8', 'SD 1.5 Q8 (mejor calidad)',
      'stable-diffusion-v1-5-pruned-emaonly-Q8_0.gguf', 1683),
  Modelo('q4', 'SD 1.5 Q4 (mas ligero)',
      'stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf', 1494),
];

const calidades = <String, int>{
  'Rapido (12 pasos)': 12,
  'Normal (20 pasos)': 20,
  'Calidad (28 pasos)': 28,
};

// Tamanos para offline (multiplos de 64, SD 1.5 trabaja mejor cerca de 512)
const sizesOffline = <String, List<int>>{
  'Cuadrado 1:1': [512, 512],
  'Vertical 9:16': [384, 640],
  'Horizontal 16:9': [640, 384],
  'Retrato 3:4': [448, 576],
};

class Motor {
  static Future<String> exe() async {
    final dir = await _canal.invokeMethod<String>('libDir');
    return '$dir/libsdcli.so';
  }

  static Future<bool> disponible() async {
    try {
      return File(await exe()).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<File> archivoModelo(Modelo m) async {
    final d = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'modelos'));
    await d.create(recursive: true);
    return File(p.join(d.path, m.archivo));
  }

  static Future<bool> descargado(Modelo m) async =>
      (await archivoModelo(m)).exists();

  static Future<void> borrar(Modelo m) async {
    final f = await archivoModelo(m);
    if (await f.exists()) await f.delete();
    final part = File('${f.path}.part');
    if (await part.exists()) await part.delete();
  }
}

class Cancelador {
  bool cancelado = false;
  http.Client? cliente;
  Process? proceso;
  void cancelar() {
    cancelado = true;
    cliente?.close();
    proceso?.kill();
  }
}

/// Descarga con reanudacion (si se corta, continua donde quedo).
Future<void> descargarModelo(
    Modelo m, void Function(int hecho, int total) progreso, Cancelador c) async {
  final destino = await Motor.archivoModelo(m);
  final part = File('${destino.path}.part');
  int inicio = await part.exists() ? await part.length() : 0;
  final cliente = http.Client();
  c.cliente = cliente;
  IOSink? sink;
  try {
    final req = http.Request('GET', Uri.parse(m.url));
    if (inicio > 0) req.headers['Range'] = 'bytes=$inicio-';
    final resp = await cliente.send(req);
    if (resp.statusCode == 416) {
      // ya estaba completo
      await part.rename(destino.path);
      return;
    }
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw 'El servidor respondio ${resp.statusCode}';
    }
    if (resp.statusCode == 200) inicio = 0; // no soporta reanudar
    int total = (resp.contentLength ?? 0) + inicio;
    final cr = resp.headers['content-range'];
    if (cr != null && cr.contains('/')) {
      total = int.tryParse(cr.split('/').last) ?? total;
    }
    sink = part.openWrite(mode: inicio > 0 ? FileMode.append : FileMode.write);
    int hecho = inicio;
    int ultimo = 0;
    await for (final trozo in resp.stream) {
      sink.add(trozo);
      hecho += trozo.length;
      final ahora = DateTime.now().millisecondsSinceEpoch;
      if (ahora - ultimo > 300) {
        ultimo = ahora;
        progreso(hecho, total);
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (total > 0 && hecho < total) throw 'Descarga incompleta';
    await part.rename(destino.path);
    progreso(total, total);
  } catch (e) {
    if (c.cancelado) throw 'Descarga cancelada';
    rethrow;
  } finally {
    await sink?.close();
    cliente.close();
  }
}

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

enum Modo { online, offline }

class Generator extends StatefulWidget {
  final VoidCallback onSaved;
  const Generator({super.key, required this.onSaved});
  @override
  State<Generator> createState() => _GeneratorState();
}

class _GeneratorState extends State<Generator> {
  final ctrl = TextEditingController();
  String style = 'Ninguno', size = 'Cuadrado 1:1';
  String calidad = 'Normal (20 pasos)';
  Modo modo = Modo.online;
  Modelo modelo = modelos.first;
  bool? modeloListo; // null = comprobando
  bool loading = false;
  bool descargando = false;
  String estado = '';
  double? progreso;
  String? error;
  File? result;
  Cancelador? cancel;

  @override
  void initState() {
    super.initState();
    _revisarModelo();
  }

  Future<void> _revisarModelo() async {
    final ok = await Motor.descargado(modelo);
    if (mounted) setState(() => modeloListo = ok);
  }

  Future<File> _nuevoArchivo(String ext) async {
    final dir = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'imagenes'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}.$ext'));
  }

  String _promptCompleto(String prompt) =>
      styles[style]!.isEmpty ? prompt : '$prompt, ${styles[style]}';

  Future<void> generate() async {
    final prompt = ctrl.text.trim();
    if (prompt.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      error = null;
      progreso = null;
      estado = '';
    });
    try {
      final File f;
      if (modo == Modo.online) {
        f = await _online(prompt);
      } else {
        f = await _offline(prompt);
      }
      await Db.add(prompt, style, f.path);
      widget.onSaved();
      if (mounted) setState(() => result = f);
    } catch (e) {
      if (mounted) setState(() => error = 'No se pudo generar: $e');
    } finally {
      cancel = null;
      if (mounted) setState(() => loading = false);
    }
  }

  Future<File> _online(String prompt) async {
    final wh = sizes[size]!;
    final seed = Random().nextInt(1 << 30);
    final uri = Uri.parse(
        '$kEndpoint${Uri.encodeComponent(_promptCompleto(prompt))}?width=${wh[0]}&height=${wh[1]}&seed=$seed&model=flux&nologo=true');
    final r = await http.get(uri).timeout(const Duration(seconds: 120));
    if (r.statusCode != 200 ||
        !(r.headers['content-type'] ?? '').startsWith('image')) {
      throw 'El servidor respondio ${r.statusCode}. Espera unos segundos e intenta de nuevo.';
    }
    final f = await _nuevoArchivo('jpg');
    await f.writeAsBytes(r.bodyBytes);
    return f;
  }

  Future<File> _offline(String prompt) async {
    if (!await Motor.disponible()) {
      throw 'El motor offline no esta incluido en este APK (solo funciona en telefonos de 64 bits).';
    }
    final mf = await Motor.archivoModelo(modelo);
    if (!await mf.exists()) throw 'Primero descarga el modelo.';
    final salida = await _nuevoArchivo('png');
    final wh = sizesOffline[size]!;
    final pasos = calidades[calidad]!;
    final seed = Random().nextInt(1 << 30);
    final args = <String>[
      '-m', mf.path,
      '-p', _promptCompleto(prompt),
      '-n', 'blurry, low quality, deformed, ugly, bad anatomy, watermark, text',
      '-o', salida.path,
      '-W', '${wh[0]}',
      '-H', '${wh[1]}',
      '--steps', '$pasos',
      '--cfg-scale', '7.0',
      '--sampling-method', 'euler_a',
      '-s', '$seed',
      '-t', '4',
    ];
    final c = Cancelador();
    cancel = c;
    setState(() => estado = 'Cargando el modelo...');
    final proc = await Process.start(await Motor.exe(), args,
        workingDirectory: (await getTemporaryDirectory()).path);
    c.proceso = proc;
    final reg = RegExp(r'(\d+)/(\d+) - ');
    final ultimas = <String>[];
    void leer(String t) {
      final m = reg.allMatches(t).toList();
      if (m.isNotEmpty) {
        final a = int.parse(m.last.group(1)!);
        final b = int.parse(m.last.group(2)!);
        if (b > 0 && mounted) {
          setState(() {
            progreso = a / b;
            estado = 'Paso $a de $b';
          });
        }
      }
      for (final l in t.split(RegExp(r'[\r\n]'))) {
        if (l.trim().isNotEmpty && !reg.hasMatch(l)) {
          ultimas.add(l.trim());
          if (ultimas.length > 8) ultimas.removeAt(0);
        }
      }
    }

    final subs = [
      proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(leer),
      proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(leer),
    ];
    final code = await proc.exitCode;
    for (final s in subs) {
      await s.cancel();
    }
    if (c.cancelado) throw 'Cancelado';
    if (code != 0 || !await salida.exists()) {
      throw 'El motor termino con error ($code).\n${ultimas.join('\n')}';
    }
    return salida;
  }

  Future<void> descargar() async {
    final c = Cancelador();
    cancel = c;
    setState(() {
      descargando = true;
      error = null;
      progreso = 0;
      estado = 'Conectando...';
    });
    try {
      await descargarModelo(modelo, (h, t) {
        if (!mounted) return;
        setState(() {
          progreso = t > 0 ? h / t : null;
          estado =
              'Descargando ${(h / 1048576).toStringAsFixed(0)} de ${(t / 1048576).toStringAsFixed(0)} MB';
        });
      }, c);
      await _revisarModelo();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      cancel = null;
      if (mounted) setState(() => descargando = false);
    }
  }

  Widget _panelOffline() {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<Modelo>(
            value: modelo,
            decoration: const InputDecoration(
                labelText: 'Modelo offline', border: OutlineInputBorder()),
            items: modelos
                .map((m) => DropdownMenuItem(
                    value: m, child: Text('${m.nombre} · ${m.mb} MB')))
                .toList(),
            onChanged: (loading || descargando)
                ? null
                : (m) {
                    setState(() {
                      modelo = m!;
                      modeloListo = null;
                    });
                    _revisarModelo();
                  },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: calidad,
            decoration: const InputDecoration(
                labelText: 'Calidad / velocidad', border: OutlineInputBorder()),
            items: calidades.keys
                .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                .toList(),
            onChanged: (v) => setState(() => calidad = v!),
          ),
          const SizedBox(height: 8),
          if (modeloListo == null)
            const Text('Comprobando modelo...')
          else if (modeloListo == false) ...[
            Text(
                'El modelo no esta en tu telefono. Se descarga una sola vez (${modelo.mb} MB, usa WiFi). Si se corta, continua donde quedo.'),
            const SizedBox(height: 8),
            if (descargando)
              Row(children: [
                Expanded(child: LinearProgressIndicator(value: progreso)),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: () => cancel?.cancelar(),
                    child: const Text('Cancelar')),
              ])
            else
              FilledButton.tonalIcon(
                  onPressed: loading ? null : descargar,
                  icon: const Icon(Icons.download),
                  label: Text('Descargar modelo (${modelo.mb} MB)')),
            if (descargando) Text(estado),
          ] else
            Row(children: [
              Icon(Icons.check_circle, color: cs.primary, size: 18),
              const SizedBox(width: 6),
              const Expanded(child: Text('Modelo listo. Funciona sin internet.')),
              TextButton(
                  onPressed: (loading || descargando)
                      ? null
                      : () async {
                          await Motor.borrar(modelo);
                          _revisarModelo();
                        },
                  child: const Text('Borrar')),
            ]),
          const SizedBox(height: 4),
          Text(
              'Offline tarda varios minutos por imagen y calienta el telefono. Deja la app abierta mientras genera. Tamano maximo ~512 px.',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offline = modo == Modo.offline;
    final tamanos = offline ? sizesOffline : sizes;
    if (!tamanos.containsKey(size)) size = tamanos.keys.first;
    final puedeGenerar =
        !loading && !descargando && (!offline || modeloListo == true);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Kornels Imagenes',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        SegmentedButton<Modo>(
          segments: const [
            ButtonSegment(
                value: Modo.online,
                icon: Icon(Icons.cloud),
                label: Text('Online')),
            ButtonSegment(
                value: Modo.offline,
                icon: Icon(Icons.phone_android),
                label: Text('Offline')),
          ],
          selected: {modo},
          onSelectionChanged: (loading || descargando)
              ? null
              : (s) => setState(() => modo = s.first),
        ),
        const SizedBox(height: 12),
        if (offline) ...[_panelOffline(), const SizedBox(height: 12)],
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
            items: tamanos.keys
                .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                .toList(),
            onChanged: (v) => setState(() => size = v!),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: puedeGenerar ? generate : null,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(loading ? 'Generando...' : 'Generar'),
            ),
          ),
          if (loading && offline) ...[
            const SizedBox(width: 8),
            OutlinedButton(
                onPressed: () => cancel?.cancelar(), child: const Text('Cancelar')),
          ],
        ]),
        if (loading && offline) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progreso),
          const SizedBox(height: 4),
          Text(estado),
        ],
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
