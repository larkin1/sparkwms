import 'package:flutter/material.dart';

import 'rust_bridge.dart';

void main() {
  runApp(const SparkWmsApp());
}

class SparkWmsApp extends StatelessWidget {
  const SparkWmsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SparkWMS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ControlPanelPage(),
    );
  }
}

class ControlPanelPage extends StatefulWidget {
  const ControlPanelPage({super.key});

  @override
  State<ControlPanelPage> createState() => _ControlPanelPageState();
}

class _ControlPanelPageState extends State<ControlPanelPage> {
  final _connectController = TextEditingController();
  final _deviceController = TextEditingController();
  final _locationController = TextEditingController();
  final _deltaController = TextEditingController(text: '1');
  final _itemController = TextEditingController();
  final _queuePathController = TextEditingController(text: 'commit_queue.json');
  final _exportPathController = TextEditingController(text: '/tmp/sparkwms.csv');

  final _log = <String>[];
  bool? _lastHealthCheck;
  int? _queueLength;
  bool _commitManagerRunning = false;
  String? _busyOperation;

  final _api = RustApi.instance;

  bool get _isBusy => _busyOperation != null;

  @override
  void dispose() {
    _connectController.dispose();
    _deviceController.dispose();
    _locationController.dispose();
    _deltaController.dispose();
    _itemController.dispose();
    _queuePathController.dispose();
    _exportPathController.dispose();
    _api.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final connect = _connectController.text.trim();
    if (connect.isEmpty) {
      _showError('Enter a connect string to continue.');
      return;
    }
    await _runOperation('Connect', () async {
      await Future<void>(() => _api.initialize(connect));
      setState(() {
        _lastHealthCheck = null;
      });
    });
  }

  void _disconnect() {
    _api.dispose();
    setState(() {
      _lastHealthCheck = null;
    });
    _appendLog('API handle disposed');
  }

  Future<void> _sendCommit() async {
    final commit = _buildCommit();
    if (commit == null) {
      return;
    }
    final result = await _runOperation('Send commit', () async {
      return Future<bool>(() => _api.sendCommit(commit));
    });
    if (result != null) {
      _appendLog(result ? 'Commit delivered to the server.' : 'Commit call returned false.');
    }
  }

  Future<void> _enqueueCommit() async {
    final commit = _buildCommit();
    if (commit == null) {
      return;
    }
    final queuePath = _queuePathValue();
    final result = await _runOperation('Queue commit', () async {
      return Future<bool>(() => _api.enqueueCommit(commit, queuePath: queuePath));
    });
    if (result != null) {
      _appendLog('Commit enqueued locally${queuePath == null ? '' : ' -> $queuePath'}');
      await _loadQueueLength();
    }
  }

  Future<void> _loadQueueLength() async {
    final queuePath = _queuePathValue();
    final length = await _runOperation('Read queue length', () async {
      return Future<int>(() => _api.queueLength(queuePath: queuePath));
    });
    if (length != null) {
      setState(() {
        _queueLength = length;
      });
      _appendLog('Queue contains $length pending commit(s).');
    }
  }

  Future<void> _checkApi() async {
    final result = await _runOperation('Health check', () async {
      return Future<bool>(() => _api.check());
    });
    if (result != null) {
      setState(() {
        _lastHealthCheck = result;
      });
      _appendLog(result ? 'API responded successfully.' : 'API is reachable but returned false.');
    }
  }

  Future<void> _startCommitManager() async {
    final connect = _connectController.text.trim();
    if (connect.isEmpty) {
      _showError('Enter a connect string first.');
      return;
    }
    final queuePath = _queuePathValue();
    final result = await _runOperation('Start commit manager', () async {
      return Future<bool>(() => _api.startCommitManager(connect, queuePath: queuePath));
    });
    if (result == true) {
      setState(() {
        _commitManagerRunning = true;
      });
      _appendLog('Commit manager thread spawned.');
    }
  }

  Future<void> _exportData(ExportTarget target) async {
    final path = _exportPathController.text.trim();
    if (path.isEmpty) {
      _showError('Provide a path to save the export.');
      return;
    }
    final label = switch (target) {
      ExportTarget.overview => 'Export overview',
      ExportTarget.locations => 'Export locations',
      ExportTarget.items => 'Export items',
    };
    final result = await _runOperation(label, () async {
      return Future<bool>(() {
        switch (target) {
          case ExportTarget.overview:
            return _api.exportOverview(path);
          case ExportTarget.locations:
            return _api.exportLocations(path);
          case ExportTarget.items:
            return _api.exportItems(path);
        }
      });
    });
    if (result == true) {
      _appendLog('$label wrote data to $path');
    }
  }

  CommitPayload? _buildCommit() {
    final device = _deviceController.text;
    final location = _locationController.text;
    final deltaText = _deltaController.text.trim();
    final itemText = _itemController.text.trim();
    final delta = int.tryParse(deltaText);
    final itemId = int.tryParse(itemText);
    if (delta == null) {
      _showError('Enter a numeric delta (positive or negative).');
      return null;
    }
    if (itemId == null) {
      _showError('Enter a numeric item ID.');
      return null;
    }
    try {
      return CommitPayload(
        deviceId: device,
        location: location,
        delta: delta,
        itemId: itemId,
      );
    } on ArgumentError catch (err) {
      _showError(err.message?.toString() ?? err.toString());
      return null;
    }
  }

  String? _queuePathValue() {
    final trimmed = _queuePathController.text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<T?> _runOperation<T>(String label, Future<T> Function() action) async {
    setState(() {
      _busyOperation = label;
    });
    try {
      final result = await action();
      _appendLog('$label succeeded');
      return result;
    } on RustApiException catch (err) {
      _appendLog('$label failed (${err.code}): ${err.message}');
      _showError(err.message);
    } catch (err) {
      _appendLog('$label failed: $err');
      _showError(err.toString());
    } finally {
      setState(() {
        _busyOperation = null;
      });
    }
    return null;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _appendLog(String message) {
    final timestamp = TimeOfDay.now().format(context);
    setState(() {
      _log.insert(0, '[$timestamp] $message');
      if (_log.length > 100) {
        _log.removeLast();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SparkWMS Control Panel'),
        actions: [
          if (_busyOperation != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  _busyOperation!,
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildConnectionCard(theme),
              const SizedBox(height: 16),
              _buildCommitCard(theme),
              const SizedBox(height: 16),
              _buildQueueCard(theme),
              const SizedBox(height: 16),
              _buildExportCard(theme),
              const SizedBox(height: 16),
              _buildLogCard(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('API Connection', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _connectController,
              decoration: const InputDecoration(
                labelText: 'Connect string',
                hintText: 'postgresql://user:pass@host:5432/db',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _isBusy ? null : _connect,
                  icon: const Icon(Icons.link),
                  label: const Text('Initialize API'),
                ),
                OutlinedButton.icon(
                  onPressed: _isBusy || !_api.isInitialized ? null : _checkApi,
                  icon: const Icon(Icons.health_and_safety),
                  label: const Text('Health check'),
                ),
                TextButton.icon(
                  onPressed: _api.isInitialized ? _disconnect : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Dispose'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusChip(
                  label: _api.isInitialized ? 'Handle ready' : 'Not connected',
                  color: _api.isInitialized ? Colors.green : Colors.red,
                ),
                if (_lastHealthCheck != null)
                  _StatusChip(
                    label: _lastHealthCheck! ? 'API healthy' : 'API reported false',
                    color: _lastHealthCheck! ? Colors.green : Colors.orange,
                  ),
                if (_commitManagerRunning)
                  const _StatusChip(
                    label: 'Commit manager running',
                    color: Colors.blue,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommitCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Commit payload', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _deviceController,
                    decoration: const InputDecoration(labelText: 'Device ID'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _locationController,
                    decoration: const InputDecoration(labelText: 'Location'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _deltaController,
                    decoration: const InputDecoration(labelText: 'Delta'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _itemController,
                    decoration: const InputDecoration(labelText: 'Item ID'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _isBusy || !_api.isInitialized ? null : _sendCommit,
                  icon: const Icon(Icons.send),
                  label: const Text('Send now'),
                ),
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _enqueueCommit,
                  icon: const Icon(Icons.queue),
                  label: const Text('Enqueue locally'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Commit queue', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _queuePathController,
              decoration: const InputDecoration(
                labelText: 'Queue file (optional)',
                hintText: 'commit_queue.json',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _loadQueueLength,
                  icon: const Icon(Icons.storage),
                  label: const Text('Refresh length'),
                ),
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _startCommitManager,
                  icon: const Icon(Icons.play_circle),
                  label: const Text('Start commit manager'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Pending commits: ${_queueLength?.toString() ?? 'unknown'}'),
          ],
        ),
      ),
    );
  }

  Widget _buildExportCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Exports', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _exportPathController,
              decoration: const InputDecoration(
                labelText: 'Export destination path',
                hintText: '/tmp/export.csv',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _isBusy || !_api.isInitialized
                      ? null
                      : () => _exportData(ExportTarget.overview),
                  icon: const Icon(Icons.table_view),
                  label: const Text('Overview'),
                ),
                ElevatedButton.icon(
                  onPressed: _isBusy || !_api.isInitialized
                      ? null
                      : () => _exportData(ExportTarget.locations),
                  icon: const Icon(Icons.location_on),
                  label: const Text('Locations'),
                ),
                ElevatedButton.icon(
                  onPressed: _isBusy || !_api.isInitialized
                      ? null
                      : () => _exportData(ExportTarget.items),
                  icon: const Icon(Icons.inventory),
                  label: const Text('Items'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Activity log', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: _log.isEmpty
                  ? const Center(child: Text('No activity yet.'))
                  : ListView.separated(
                      itemCount: _log.length,
                      separatorBuilder: (_, __) => const Divider(height: 12),
                      itemBuilder: (context, index) => Text(_log[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final borderColor = color.withOpacity(0.4);
    final textColor = color.withOpacity(0.9);
    return Chip(
      backgroundColor: color.withOpacity(0.12),
      side: BorderSide(color: borderColor),
      label: Text(
        label,
        style: TextStyle(color: textColor),
      ),
    );
  }
}

enum ExportTarget { overview, locations, items }
