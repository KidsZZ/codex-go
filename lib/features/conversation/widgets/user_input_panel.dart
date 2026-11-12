// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';

import 'package:codex_go/infrastructure/codex/user_input_request.dart';
import 'package:codex_go/features/conversation/widgets/markdown_content.dart';
import 'package:codex_go/l10n/strings.dart';

class UserInputPanel extends StatefulWidget {
  const UserInputPanel({
    required this.request,
    required this.onAnswer,
    super.key,
  });

  final UserInputRequest request;
  final void Function(Map<String, String>) onAnswer;

  @override
  State<UserInputPanel> createState() => _UserInputPanelState();
}

class _UserInputPanelState extends State<UserInputPanel> {
  final _selected = <String, String>{};
  final _custom = <String, String>{};
  final _useCustom = <String>{};

  Map<String, String> get answers => {
    for (final q in widget.request.questions)
      q.id: q.options.isEmpty || _useCustom.contains(q.id)
          ? _custom[q.id] ?? ''
          : _selected[q.id] ?? '',
  };

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: ExpansionTile(
      initiallyExpanded: true,
      title: Text(
        widget.request.isBlocking
            ? context.l10n.answerToContinue
            : context.l10n.questionsForYou,
      ),
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.3,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final q in widget.request.questions) ...[
                  Text(q.header, style: Theme.of(context).textTheme.titleSmall),
                  MarkdownContent(text: q.question),
                  for (final option in q.options)
                    ListTile(
                      dense: true,
                      title: MarkdownContent(
                        text: option.label,
                        selectable: false,
                      ),
                      subtitle: option.description.isEmpty
                          ? null
                          : MarkdownContent(
                              text: option.description,
                              selectable: false,
                            ),
                      leading: Icon(
                        !_useCustom.contains(q.id) &&
                                _selected[q.id] == option.label
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      selected:
                          !_useCustom.contains(q.id) &&
                          _selected[q.id] == option.label,
                      onTap: () => setState(() {
                        _useCustom.remove(q.id);
                        _selected[q.id] = option.label;
                      }),
                    ),
                  if (q.options.isEmpty || q.isOther)
                    TextField(
                      key: ValueKey('answer-${q.id}'),
                      obscureText: q.isSecret,
                      autocorrect: !q.isSecret,
                      enableSuggestions: !q.isSecret,
                      decoration: InputDecoration(
                        labelText: context.l10n.yourAnswer,
                      ),
                      onChanged: (value) => setState(() {
                        _useCustom.add(q.id);
                        _custom[q.id] = value;
                      }),
                    ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => widget.onAnswer({}),
              child: Text(context.l10n.skip),
            ),
            FilledButton(
              onPressed:
                  answers.values.every((value) => value.trim().isNotEmpty)
                  ? () => widget.onAnswer(answers)
                  : null,
              child: Text(context.l10n.submitAnswers),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ],
    ),
  );
}
