import 'package:flutter/material.dart';
import '../services/GrokService.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _response = '';

  void _askAI() async {
    try {
      String reply = await callGrok("Hello!"); // ✅ changed here
      setState(() {
        _response = reply;
      });
    } catch (e) {
      setState(() {
        _response = "Error: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Grok Chat')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(_response),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _askAI,
              child: Text('Ask Grok'),
            ),
          ],
        ),
      ),
    );
  }
}