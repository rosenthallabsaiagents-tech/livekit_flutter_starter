import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../controllers/app_ctrl.dart';

class RecoveryHelpScreen extends StatefulWidget {
  const RecoveryHelpScreen({super.key, required this.appCtrl});

  final AppCtrl appCtrl;

  @override
  State<RecoveryHelpScreen> createState() => _RecoveryHelpScreenState();
}

class _RecoveryHelpScreenState extends State<RecoveryHelpScreen> {
  static const int _maxPages = 5;
  static const int _maxTotalBytes = 12 * 1024 * 1024;
  static const int _maxOnePageBytes = 10 * 1024 * 1024;

  final ImagePicker _picker = ImagePicker();
  final TextEditingController _questionController = TextEditingController();
  final List<_WorksheetPage> _pages = [];
  bool _isAnalyzing = false;
  bool _isSendingToJarvis = false;
  String? _helpText;
  String? _errorText;

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _chooseCameraPage() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1800,
      imageQuality: 82,
    );
    if (file != null) await _addPages([file]);
  }

  Future<void> _chooseLibraryPages() async {
    final files = await _picker.pickMultiImage(maxWidth: 1800, imageQuality: 82);
    if (files.isNotEmpty) await _addPages(files);
  }

  Future<void> _addPages(Iterable<XFile> files) async {
    var total = _pages.fold<int>(0, (sum, page) => sum + page.bytes.length);
    final added = <_WorksheetPage>[];
    for (final file in files) {
      if (_pages.length + added.length >= _maxPages) {
        _showError('Choose up to five pages from one assignment.');
        break;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxOnePageBytes) {
        _showError('Each photo must be smaller than 10 MB. Try a closer crop.');
        continue;
      }
      total += bytes.length;
      if (total > _maxTotalBytes) {
        _showError('The selected photos must total no more than 12 MB.');
        break;
      }
      added.add(_WorksheetPage(bytes: bytes, mimeType: _mimeType(file)));
    }
    if (!mounted) return;
    setState(() {
      _pages.addAll(added);
      _helpText = null;
      _errorText = null;
    });
  }

  String _mimeType(XFile file) {
    final provided = file.mimeType?.toLowerCase();
    if (provided != null && provided.startsWith('image/')) return provided;
    final ext = file.path.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
  }

  Future<void> _analyze() async {
    if (_pages.isEmpty) {
      _showError('Take a photo or choose at least one worksheet page first.');
      return;
    }
    final rootUrl = dotenv.env['RECOVERY_HELP_API_URL']?.trim() ?? '';
    if (rootUrl.isEmpty) {
      _showError('Recovery Help is not connected yet. The service URL needs to be configured in the iPhone build.');
      return;
    }

    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send worksheet photos to Gemini?'),
        content: const Text(
          'The selected photos and your optional question will be sent to Google Gemini through Recovery Help for analysis. This app does not save them. Crop out names, faces, room numbers, signatures, and completed personal logs first.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Send photos to Gemini')),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() {
      _isAnalyzing = true;
      _helpText = null;
      _errorText = null;
    });
    try {
      final normalizedRoot = rootUrl.endsWith('/') ? rootUrl.substring(0, rootUrl.length - 1) : rootUrl;
      final uri = Uri.parse('$normalizedRoot/api/coach');
      final payload = {
        'question': _questionController.text.trim(),
        'images': _pages
            .map((page) => {
                  'mime_type': page.mimeType,
                  'data': base64Encode(page.bytes),
                })
            .toList(),
      };
      final response = await http
          .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 75));
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) throw Exception('The worksheet service returned an unreadable response.');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(decoded['detail']?.toString() ?? 'The worksheet could not be analyzed.');
      }
      final result = decoded['help']?.toString().trim() ?? '';
      if (result.isEmpty) throw Exception('No worksheet guidance came back. Try a clearer photo.');
      if (!mounted) return;
      setState(() => _helpText = result);
    } catch (error) {
      if (!mounted) return;
      _showError('Could not analyze the worksheet. ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _discussWithJarvis() async {
    final help = _helpText;
    if (help == null) return;
    setState(() => _isSendingToJarvis = true);
    final userNote = _questionController.text.trim();
    final message = '''A separate Recovery Help Assignments coach reviewed my worksheet photo. Its question-by-question guidance is below. Please help me understand it, ask me one reflective question at a time, and help me put my own answer in my own words. Do not invent personal experiences or pressure me to disclose trauma or other sensitive history. You are not my clinician or CASAC; for personal treatment questions, encourage me to talk with my counselor or staff.

${userNote.isEmpty ? '' : 'My question or notes: $userNote\n\n'}Worksheet coach guidance:
$help''';
    try {
      final sent = await widget.appCtrl.sendAssignmentContextToJarvis(message);
      if (!mounted) return;
      if (!sent) {
        _showError('Connect to Jarvis first, then send the worksheet guidance again.');
      } else {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) _showError('Jarvis could not receive the worksheet guidance. Please try again.');
    } finally {
      if (mounted) setState(() => _isSendingToJarvis = false);
    }
  }

  void _removePage(int index) {
    setState(() {
      _pages.removeAt(index);
      _helpText = null;
      _errorText = null;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorText = message);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery Help Assignments')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Text(
              'Take a photo or choose up to five pages from one assignment. The coach will explain each question and offer ideas to help you form your own answers.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 14),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Use this outside class if phones must be put away. Classmates’ stories should stay private. You can skip any question that feels too personal.',
                  style: TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isAnalyzing ? null : _chooseCameraPage,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Take photo'),
                ),
                OutlinedButton.icon(
                  onPressed: _isAnalyzing ? null : _chooseLibraryPages,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Choose photos'),
                ),
              ],
            ),
            if (_pages.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${_pages.length} page${_pages.length == 1 ? '' : 's'} selected',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(_pages[i].bytes, width: 82, height: 106, fit: BoxFit.cover),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: IconButton.filledTonal(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _removePage(i),
                            tooltip: 'Remove page ${i + 1}',
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _questionController,
              enabled: !_isAnalyzing,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Question or note (optional)',
                hintText: 'For example: Help me understand question 2.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isAnalyzing ? null : _analyze,
              icon: _isAnalyzing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(_isAnalyzing ? 'Reading the worksheet…' : 'Analyze photos with Gemini'),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Text(_errorText!, style: TextStyle(color: colorScheme.error)),
            ],
            if (_helpText != null) ...[
              const SizedBox(height: 20),
              Text('Ideas to get you started', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              SelectableText(_helpText!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isSendingToJarvis ? null : _discussWithJarvis,
                icon: _isSendingToJarvis
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.record_voice_over_outlined),
                label: Text(_isSendingToJarvis ? 'Sending to Jarvis…' : 'Discuss this with Jarvis'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Jarvis receives the worksheet guidance and your optional note as text. The photo itself is not sent through the LiveKit voice session.',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorksheetPage {
  const _WorksheetPage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}
