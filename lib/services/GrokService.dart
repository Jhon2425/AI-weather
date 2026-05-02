import 'package:http/http.dart' as http;
import 'dart:convert';

Future<String> callGrok(String prompt) async {
  final response = await http.post(
    Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer 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',
    },
    body: jsonEncode({
      'model': 'llama-3.3-70b-versatile',
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
      'max_tokens': 1024,
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'].toString();
  } else {
    throw Exception('Error: ${response.statusCode} ${response.body}');
  }
}