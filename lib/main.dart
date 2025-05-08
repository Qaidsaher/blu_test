import 'dart:async';
import 'dart:convert'; // For utf8.decode

import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Bluetooth Serial Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const BluetoothHomePage(),
    );
  }
}

class BluetoothHomePage extends StatefulWidget {
  const BluetoothHomePage({super.key});

  @override
  State<BluetoothHomePage> createState() => _BluetoothHomePageState();
}

class _BluetoothHomePageState extends State<BluetoothHomePage> {
  final FlutterBluetoothSerial _bluetooth = FlutterBluetoothSerial.instance;

  // State variables
  BluetoothState _bluetoothState = BluetoothState.UNKNOWN;
  List<BluetoothDevice> _devicesList = [];
  BluetoothDevice? _selectedDevice;
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isDiscovering = false;
  String _receivedData = "";
  StreamSubscription<BluetoothDiscoveryResult>? _discoveryStreamSubscription;
  StreamSubscription<Uint8List>? _dataStreamSubscription;

  // State variable to track if initial permission check is done
  bool _initialPermissionCheckDone = false;

  @override
  void initState() {
    super.initState();
    // Check initial status but don't block UI based on it initially
    _checkPermissionsStatusInitial();
    _getBluetoothState(); // Get initial Bluetooth state
    _setupStateChangeListener(); // Listen for Bluetooth state changes
  }

  @override
  void dispose() {
    // Avoid memory leaks and disconnect properly
    _discoveryStreamSubscription?.cancel();
    _dataStreamSubscription?.cancel();
    // FIX: Removed await from dispose as it likely returns void
    _connection?.dispose();
    super.dispose();
  }

  // --- Permission Handling (Revised Again for Explicit Request) ---

  // Check the current status on init, mainly for logging
  Future<void> _checkPermissionsStatusInitial() async {
    if (kIsWeb) {
      if (mounted)
        setState(() {
          _initialPermissionCheckDone = true;
        });
      return;
    }
    bool scanGranted = await Permission.bluetoothScan.isGranted;
    bool connectGranted = await Permission.bluetoothConnect.isGranted;
    bool locationGranted =
        await Permission.locationWhenInUse.isGranted; // Or .location
    print("Initial Permissions Check:");
    print("  BluetoothScan: $scanGranted");
    print("  BluetoothConnect: $connectGranted");
    print("  LocationWhenInUse: $locationGranted");
    if (mounted)
      setState(() {
        _initialPermissionCheckDone = true;
      });
  }

  // Request permissions explicitly when needed (e.g., before scanning)
  Future<bool> _requestPermissions() async {
    // Add a log to show this function is being called
    print("--- Attempting to request permissions ---");

    if (kIsWeb) {
      print("Running on web, skipping native permissions.");
      return true; // Assume granted for web
    }

    // List of permissions needed
    List<Permission> permissionsToRequest = [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission
          .locationWhenInUse, // Keep this, as it's often required for scanning
    ];

    // Request permissions
    Map<Permission, PermissionStatus> statuses =
        await permissionsToRequest.request();

    // Check results and log them
    bool allGranted = true;
    List<String> deniedPermissions = [];
    print("--- Permission Request Results ---");
    statuses.forEach((permission, status) {
      print("  ${permission.toString()}: $status");
      if (!status.isGranted) {
        allGranted = false;
        // Add user-friendly names
        if (permission == Permission.bluetoothScan)
          deniedPermissions.add("Bluetooth Scan");
        if (permission == Permission.bluetoothConnect)
          deniedPermissions.add("Bluetooth Connect");
        if (permission == Permission.locationWhenInUse)
          deniedPermissions.add("Location (for scanning)");

        _handlePermissionDenied(
          permission,
          status,
        ); // Log or handle specific denials
      }
    });
    print("---------------------------------");

    if (!allGranted && mounted) {
      // Check if widget is still in the tree
      _showPermissionDeniedDialog(deniedPermissions);
    } else if (allGranted && mounted) {
      _showSnackBar("Permissions granted!");
    }

    print("Overall permission request result (allGranted): $allGranted");
    return allGranted;
  }

  // Helper to log if permission is denied/permanently denied
  void _handlePermissionDenied(
    Permission permission,
    PermissionStatus? status,
  ) {
    if (status == PermissionStatus.denied) {
      print(
        "Permission denied: ${permission.toString()}. User can be asked again.",
      );
    } else if (status == PermissionStatus.permanentlyDenied) {
      print(
        "Permission permanently denied: ${permission.toString()}. User must go to settings.",
      );
    }
  }

  // Show a dialog explaining denied permissions and guiding to settings if needed
  Future<void> _showPermissionDeniedDialog(
    List<String> deniedPermissions,
  ) async {
    if (!mounted) return;

    bool permanentlyDenied = false;
    // Check if any were permanently denied *after* the request attempt
    for (Permission p in [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ]) {
      // Use status rather than isPermanentlyDenied for more direct check after request
      PermissionStatus currentStatus = await p.status;
      if (currentStatus == PermissionStatus.permanentlyDenied) {
        permanentlyDenied = true;
        break;
      }
    }

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permissions Required'),
          content: Text(
            'The following permissions are required for Bluetooth functionality: ${deniedPermissions.join(', ')}.\n\n' +
                (permanentlyDenied
                    ? 'You have permanently denied one or more permissions. Please enable them in the app settings.'
                    : 'Please grant the required permissions to use Bluetooth features.'),
          ),
          actions: <Widget>[
            if (permanentlyDenied)
              TextButton(
                child: const Text('Open Settings'),
                onPressed: () {
                  openAppSettings(); // From permission_handler
                  Navigator.of(context).pop();
                },
              ),
            TextButton(
              child: Text(permanentlyDenied ? 'Cancel' : 'OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // --- Bluetooth State Handling ---
  // This function updates state, doesn't need to return a Future itself
  void _getBluetoothState() async {
    try {
      _bluetoothState = await FlutterBluetoothSerial.instance.state;
      if (_bluetoothState == BluetoothState.STATE_OFF && mounted) {
        _showSnackBar("Bluetooth is currently off.");
      }
    } catch (e) {
      print("Error getting Bluetooth state: $e");
      _bluetoothState = BluetoothState.UNKNOWN; // Set to unknown on error
    } finally {
      if (mounted) setState(() {}); // Update UI regardless of outcome
    }
  }

  void _setupStateChangeListener() {
    FlutterBluetoothSerial.instance.onStateChanged().listen((
      BluetoothState state,
    ) {
      print("Bluetooth state changed to: $state");
      if (mounted) {
        // Ensure widget is still mounted
        setState(() {
          _bluetoothState = state;
        });
        // If Bluetooth turns off, update connection status and clear lists
        if (_bluetoothState == BluetoothState.STATE_OFF ||
            _bluetoothState == BluetoothState.STATE_TURNING_OFF) {
          if (_isConnected) {
            _disconnect(); // Gracefully disconnect if connected
          } else {
            // Clear lists even if not connected
            setState(() {
              _devicesList = [];
              _selectedDevice = null;
              _isDiscovering =
                  false; // Stop discovery indication if BT turns off
            });
          }
        }
      }
    });
  }

  // --- Device Discovery (Revised for explicit permission request) ---
  void _startDiscovery() async {
    print("'Scan Devices' button pressed.");

    // 1. Always attempt to request permissions when scan is initiated
    print("Requesting permissions before starting discovery...");
    bool permissionsGranted = await _requestPermissions();

    // 2. Check if permissions were actually granted *after* the request
    if (!permissionsGranted) {
      print(
        "Permissions were not granted after request. Cannot start discovery.",
      );
      return; // Exit if permissions were not granted
    }
    print(
      "Permissions appear to be granted. Proceeding with discovery checks.",
    );

    // 3. Check if Bluetooth is ON (after ensuring permissions)
    // FIX: Removed await from _getBluetoothState call
    _getBluetoothState(); // Refresh state just in case
    await Future.delayed(
      const Duration(milliseconds: 100),
    ); // Short delay to allow state update
    if (_bluetoothState != BluetoothState.STATE_ON) {
      if (mounted)
        _showSnackBar("Please turn on Bluetooth to scan for devices.");
      return;
    }

    // 4. Start Actual Discovery
    if (mounted) {
      setState(() {
        _isDiscovering = true;
        _devicesList = []; // Clear previous results
      });
    }
    print("Starting Bluetooth discovery process...");
    if (mounted) _showSnackBar("Scanning for devices...");

    _discoveryStreamSubscription?.cancel(); // Cancel previous stream if any
    _discoveryStreamSubscription = _bluetooth.startDiscovery().listen(
      (r) {
        // Filter out devices with no name or address early
        if (r.device.name == null ||
            r.device.name!.isEmpty ||
            r.device.address.isEmpty) {
          return;
        }

        final existingIndex = _devicesList.indexWhere(
          (device) => device.address == r.device.address,
        );
        if (existingIndex < 0) {
          // Add new device only if not already in the list
          if (mounted)
            setState(() {
              _devicesList.add(r.device);
            });
        }
      },
      onError: (error) {
        print('Discovery Error: $error');
        if (mounted) _showSnackBar('Device discovery failed: $error');
        if (mounted)
          setState(() {
            _isDiscovering = false;
          });
      },
      onDone: () {
        print('Discovery finished.');
        if (mounted)
          setState(() {
            _isDiscovering = false;
          });
      },
      cancelOnError: true,
    );
  }

  void _stopDiscovery() {
    print("Stopping device discovery...");
    _bluetooth.cancelDiscovery();
    _discoveryStreamSubscription?.cancel();
    if (mounted) {
      setState(() {
        _isDiscovering = false;
      });
    }
    print("Stopped device discovery.");
  }

  // --- Connection Handling ---
  void _connectToDevice(BluetoothDevice device) async {
    if (_isConnected || _connection != null) {
      if (mounted)
        _showSnackBar("Already connected or connection attempt in progress.");
      return;
    }
    // Stop discovery if it's running
    if (_isDiscovering) {
      await _bluetooth
          .cancelDiscovery(); // This returns Future<void>, await is okay
      if (mounted)
        setState(() {
          _isDiscovering = false;
        });
      print("Stopped discovery before connecting.");
      await Future.delayed(
        const Duration(milliseconds: 200),
      ); // Small delay after stopping discovery
    }

    print("Attempting to connect to ${device.name ?? device.address}...");
    if (mounted)
      _showSnackBar("Connecting to ${device.name ?? device.address}...");

    try {
      // Check connect permission one last time before attempting
      if (!kIsWeb && !(await Permission.bluetoothConnect.isGranted)) {
        if (mounted) _showSnackBar("Bluetooth Connect permission needed.");
        bool granted = await _requestPermissions();
        if (!granted) {
          print("Connect permission denied, cannot connect.");
          return;
        }
      }

      BluetoothConnection connection = await BluetoothConnection.toAddress(
        device.address,
      );
      print('Connected to the device: ${device.name ?? device.address}');

      if (mounted) {
        setState(() {
          _connection = connection;
          _isConnected = true;
          _selectedDevice = device;
          _receivedData = "";
        });
        _showSnackBar("Connected to ${device.name ?? device.address}");
        _listenForData();
      } else {
        // If widget was disposed during connection attempt, close the connection
        connection.close(); // close() likely returns void
      }
    } catch (exception) {
      print('Cannot connect, exception occurred: $exception');
      String errorMsg = 'Connection Failed';
      if (exception.toString().toLowerCase().contains('permission') ||
          exception.toString().contains('13')) {
        errorMsg = 'Connection Failed: Missing Permissions?';
      } else if (exception.toString().contains('unavailable') ||
          exception.toString().contains('busy')) {
        errorMsg = 'Connection Failed: Device unavailable/busy?';
      } else if (exception.toString().contains('socket')) {
        errorMsg = 'Connection Failed: Socket error';
      }
      if (mounted) _showSnackBar(errorMsg);
      if (mounted) {
        setState(() {
          _isConnected = false;
          _connection = null;
          _selectedDevice = null;
        });
      }
    }
  }

  void _disconnect() async {
    print("Disconnecting from ${_selectedDevice?.name ?? 'device'}...");
    if (mounted) _showSnackBar("Disconnecting...");

    // Cancel the stream subscription first
    await _dataStreamSubscription?.cancel();
    _dataStreamSubscription = null;

    // Then dispose the connection
    // FIX: Removed await from dispose as it likely returns void
    _connection?.dispose();
    _connection = null;

    // Update state last
    if (mounted) {
      setState(() {
        _isConnected = false;
        _selectedDevice = null;
        _receivedData = "";
      });
      _showSnackBar("Disconnected");
    }
    print("Disconnected.");
  }

  // --- Data Handling ---
  void _listenForData() {
    _dataStreamSubscription?.cancel(); // Ensure no duplicate listeners
    print("Starting to listen for data...");
    _dataStreamSubscription = _connection?.input?.listen(
      (Uint8List data) {
        String receivedString = utf8.decode(data, allowMalformed: true);
        print('Data received chunk: $receivedString');
        if (mounted) {
          setState(() {
            _receivedData += receivedString; // Append received data
          });
        }
      },
      onDone: () {
        print('Input stream closed (device disconnected).');
        if (mounted) {
          _showSnackBar("Device disconnected.");
          _disconnect(); // Trigger local disconnect logic
        }
      },
      onError: (error) {
        print('Data stream error: $error');
        if (mounted) {
          _showSnackBar('Connection error: $error');
          _disconnect(); // Disconnect on error
        }
      },
      cancelOnError: true,
    );
  }

  void _sendData(String data) async {
    if (_connection?.isConnected ?? false) {
      try {
        String dataToSend =
            data + "\r\n"; // Ensure newline if needed by peripheral
        _connection!.output.add(Uint8List.fromList(utf8.encode(dataToSend)));
        await _connection!
            .output
            .allSent; // allSent returns Future<void>, await is okay
        print('Sent data: $data');
        if (mounted) _showSnackBar('Sent: $data');
      } catch (e) {
        print('Error sending data: $e');
        if (mounted) _showSnackBar('Error sending data: $e');
        if (mounted) {
          // Handle send error - maybe show error state, don't necessarily disconnect
        }
      }
    } else {
      if (mounted) _showSnackBar('Not connected to any device.');
    }
  }

  // --- UI Helper ---
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // --- Widgets ---

  Widget _buildControlButtons() {
    bool canScan =
        !_isDiscovering && _bluetoothState == BluetoothState.STATE_ON;
    bool canDisconnect = _isConnected;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _bluetoothState == BluetoothState.STATE_ON
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color:
                    _bluetoothState == BluetoothState.STATE_ON
                        ? Colors.blue
                        : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                "Bluetooth: ${_bluetoothState.toString().split('.').last.replaceAll('STATE_', '')}",
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              ElevatedButton.icon(
                icon:
                    _isDiscovering
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : const Icon(Icons.search),
                label: Text(_isDiscovering ? 'Scanning...' : 'Scan Devices'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(140, 40),
                  disabledBackgroundColor: Colors.grey.shade400,
                ),
                onPressed: canScan ? _startDiscovery : null,
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop Scan'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(140, 40),
                  disabledBackgroundColor: Colors.grey.shade400,
                ),
                onPressed: _isDiscovering ? _stopDiscovery : null,
              ),
            ],
          ),
          const SizedBox(height: 15),
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                minimumSize: const Size(160, 40),
                disabledBackgroundColor: Colors.grey.shade400,
              ),
              onPressed: canDisconnect ? _disconnect : null,
            ),
          ),
          if (_isConnected && _selectedDevice != null)
            Padding(
              padding: const EdgeInsets.only(top: 15.0),
              child: Chip(
                avatar: const Icon(
                  Icons.bluetooth_connected,
                  color: Colors.white,
                ),
                label: Text(
                  "Connected: ${_selectedDevice!.name ?? _selectedDevice!.address}",
                ),
                backgroundColor: Colors.green,
                labelStyle: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    if (_bluetoothState != BluetoothState.STATE_ON) {
      return const Expanded(
        child: Center(child: Text("Please turn on Bluetooth.")),
      );
    }

    Widget listContent;
    if (_isDiscovering) {
      listContent =
          _devicesList.isEmpty
              ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text("Scanning..."),
                  ],
                ),
              )
              : ListView.builder(
                itemCount: _devicesList.length,
                itemBuilder: _buildDeviceListItem,
              );
    } else {
      listContent =
          _devicesList.isEmpty
              ? const Center(
                child: Text('No devices found. Press "Scan Devices".'),
              )
              : ListView.builder(
                itemCount: _devicesList.length,
                itemBuilder: _buildDeviceListItem,
              );
    }

    return Expanded(child: listContent);
  }

  Widget _buildDeviceListItem(BuildContext context, int index) {
    BluetoothDevice device = _devicesList[index];
    return ListTile(
      leading: const Icon(Icons.devices),
      title: Text(device.name ?? 'Unknown Device'),
      subtitle: Text(device.address),
      trailing: ElevatedButton(
        child: const Text('Connect'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueAccent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
        ),
        onPressed: _isConnected ? null : () => _connectToDevice(device),
      ),
      onTap: _isConnected ? null : () => _connectToDevice(device),
    );
  }

  Widget _buildDataSection() {
    final TextEditingController sendTextController = TextEditingController();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Communication Log:",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Container(
            height: 200,
            width: double.infinity,
            padding: const EdgeInsets.all(10.0),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.blueGrey.shade100),
              borderRadius: BorderRadius.circular(8.0),
              color: Colors.grey.shade50,
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(_receivedData),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "Send Message:",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: sendTextController,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    hintText: 'Type message...',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (value) {
                    if (value.isNotEmpty) {
                      _sendData(value);
                      sendTextController.clear();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                tooltip: "Send Message",
                onPressed: () {
                  final textToSend = sendTextController.text;
                  if (textToSend.isNotEmpty) {
                    _sendData(textToSend);
                    sendTextController.clear();
                  } else {
                    if (mounted) _showSnackBar("Cannot send empty message.");
                  }
                },
                style: IconButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Bluetooth Serial'),
        backgroundColor: Colors.blueGrey.shade700,
      ),
      backgroundColor: Colors.grey.shade100,
      body: Column(
        children: <Widget>[
          _buildControlButtons(),
          const Divider(height: 1, thickness: 1),
          _buildDeviceList(),
          if (_isConnected) ...[
            const Divider(height: 1, thickness: 1),
            _buildDataSection(),
          ],
        ],
      ),
    );
  }
}
