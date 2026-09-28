// Reads Dart sources through the language's own parser, for the guards that assert something about
// how a tree of Dart files is written.
//
// WHY A PARSER AND NOT A PATTERN. A pattern spells one *shape* of what it looks for — a call written
// on one line, a name that is not inside a comment, a declaration that starts at column 0 — and every
// other shape of the same thing is then absent from what it finds rather than reported. The formatter
// alone produces several shapes of one call (it breaks a method chain before the dot), so a guard
// written as a pattern ends up constraining how `lib/` may be formatted. A syntax tree has one node
// for a call however it is laid out. `video_import_report_fields_test.dart` states the same rule for
// its own enumeration.
//
// WHAT A SYNTAX TREE STILL CANNOT SAY. The parse is unresolved: an identifier is a name, not the
// declaration it resolves to. `archiver.archive(…)` is a call of *some* `archive`, and whether
// `archiver` holds the controller a guard is looking for is a question about types that nothing here
// answers. A guard built on this reads names and the shape of the expression around them, and says
// so where that matters.
//
// COMMENTS ARE NOT CODE. `//` comments and the contents of string literals never become nodes. Doc
// comments do — a `[name]` reference in one parses as an identifier — so every walk here skips them.
// An expression interpolated into a string *is* code, and is walked like any other.
import 'dart:io';

// `analyzer` reaches this package transitively (through the codegen stack). Depended on here rather
// than promoted to a direct dev_dependency because pinning it would freeze the version the codegen
// packages resolve to, and these helpers only ever need the parser. Same arrangement as
// `pump_loop_bound_guard_test.dart` and `video_import_report_fields_test.dart`.
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/analysis/utilities.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/ast.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/dart/ast/visitor.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/diagnostic/diagnostic.dart';
// ignore: depend_on_referenced_packages
import 'package:analyzer/source/line_info.dart';

/// One Dart source, parsed.
final class ParsedSource {
  ParsedSource._(this.path, this.content, this.unit, this.diagnostics, this._lines);

  /// Parses [content], which is reported as coming from [path].
  ///
  /// Never throws on a syntax error: the parser recovers and the error lands in [diagnostics], which
  /// is where a guard has to look before it believes that something is absent.
  factory ParsedSource.parse(String content, {required String path}) {
    final result = parseString(content: content, throwIfDiagnostics: false);
    return ParsedSource._(path, content, result.unit, result.errors, result.lineInfo);
  }

  /// Slash-separated, relative to the directory the tree was listed from (`lib/src/…`).
  final String path;

  final String content;

  final CompilationUnit unit;

  /// What the parser could not read.
  ///
  /// Empty for every file that compiles. A unit with diagnostics is a recovery tree — whole
  /// statements can be missing from it — so a guard that reports "nothing found" over one has not
  /// looked at the file it names.
  final List<Diagnostic> diagnostics;

  final LineInfo _lines;

  /// `path:line` of [node], for a finding a reader has to be able to open.
  String locate(AstNode node) => '$path:${_lines.getLocation(node.offset).lineNumber}';
}

/// The Dart file at [path], parsed.
ParsedSource parseDartFile(String path) => ParsedSource.parse(File(path).readAsStringSync(), path: path);

/// Every `.dart` file under [root], parsed, in path order.
List<ParsedSource> parseDartTree(String root) {
  final files = Directory(root).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
  return [for (final file in files) ParsedSource.parse(file.readAsStringSync(), path: file.path.replaceAll(r'\', '/'))]
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Every node of type [T] at or under [root], in source order, outside doc comments.
List<T> nodesOf<T extends AstNode>(AstNode root) {
  final collector = _NodesOf<T>();
  root.accept(collector);
  return collector.found;
}

class _NodesOf<T extends AstNode> extends GeneralizingAstVisitor<void> {
  final List<T> found = [];

  @override
  void visitComment(Comment node) {}

  @override
  void visitNode(AstNode node) {
    if (node is T) {
      found.add(node);
    }
    super.visitNode(node);
  }
}

/// One use of a name as code: a call, a tear-off, a property read, or a bare reference.
///
/// [identifier] is the name itself, which is where a finding about it should point. [receiver] is what
/// the name was reached through — the target of `x.name` or `x.name(…)`, and for a cascade the
/// cascade's target — and `null` for a bare name (a top-level function, a local, or a member reached
/// through an implicit `this`). [arguments] is the call's argument list, and `null` when the name is
/// referred to without being called. [node] is the whole expression.
typedef NameReference = ({
  String name,
  SimpleIdentifier identifier,
  Expression? receiver,
  ArgumentList? arguments,
  AstNode node,
});

/// Every [NameReference] at or under [root], in source order.
///
/// A declaration's own name is not a reference (the parser stores it as a token, not an
/// identifier), and neither is a named argument's label or a name listed in an import's `show` /
/// `hide`.
List<NameReference> referencesIn(AstNode root) => [
  for (final identifier in nodesOf<SimpleIdentifier>(root)) ?_referenceOf(identifier),
];

NameReference? _referenceOf(SimpleIdentifier identifier) {
  final parent = identifier.parent;
  if (parent is Label || parent is Combinator || identifier.inDeclarationContext()) {
    return null;
  }
  final name = identifier.name;
  if (parent is MethodInvocation && identifier == parent.methodName) {
    return (
      name: name,
      identifier: identifier,
      receiver: parent.realTarget,
      arguments: parent.argumentList,
      node: parent,
    );
  }
  if (parent is PrefixedIdentifier && identifier == parent.identifier) {
    return (name: name, identifier: identifier, receiver: parent.prefix, arguments: null, node: parent);
  }
  if (parent is PropertyAccess && identifier == parent.propertyName) {
    return (name: name, identifier: identifier, receiver: parent.realTarget, arguments: null, node: parent);
  }
  return (name: name, identifier: identifier, receiver: null, arguments: null, node: identifier);
}

/// The type every `new` / `const` constructor invocation at or under [root] creates, in source order,
/// with the invocation itself.
///
/// These are not [NameReference]s: the parser stores the type of `new X()` and `const X()` as a type
/// name, not as an identifier. A bare `X()` is a [MethodInvocation] in an unresolved parse, so it is
/// found by [referencesIn] and not here.
/// Every call of a function or method named [name] at or under [root], in source order: the
/// [NameReference]s to [name] that carry an argument list. A tear-off is not a call.
List<NameReference> callsOf(AstNode root, String name) => [
  for (final reference in referencesIn(root))
    if (reference.name == name && reference.arguments != null) reference,
];

/// The name a top-level declaration declares, or `null` for one that declares none (an unnamed
/// extension). A variable declaration answers its names joined with `, `.
String? topLevelName(CompilationUnitMember declaration) => switch (declaration) {
  NamedCompilationUnitMember(:final name) => name.lexeme,
  ExtensionDeclaration(:final name) => name?.lexeme,
  TopLevelVariableDeclaration(:final variables) => variables.variables.map((v) => v.name.lexeme).join(', '),
  _ => null,
};

/// The top-level declaration of type [T] named [name] in [unit], or `null` when there is none.
T? topLevelDeclaration<T extends CompilationUnitMember>(CompilationUnit unit, String name) {
  for (final declaration in unit.declarations.whereType<T>()) {
    if (topLevelName(declaration) == name) {
      return declaration;
    }
  }
  return null;
}

/// The method [name] declared in the class [type] in [unit], or `null` when there is none.
MethodDeclaration? methodDeclaration(CompilationUnit unit, String type, String name) {
  final declaration = topLevelDeclaration<ClassDeclaration>(unit, type);
  if (declaration == null) {
    return null;
  }
  for (final method in declaration.members.whereType<MethodDeclaration>()) {
    if (method.name.lexeme == name) {
      return method;
    }
  }
  return null;
}

/// The declaration [node] is written in: `Type.member` inside a class, mixin, enum or extension
/// member, the top-level name inside a top-level function or variable, and `null` outside both (a
/// directive).
///
/// The *member*, not the innermost function: a closure or a local function belongs to the member
/// that contains it, because that is the unit a reader of the file can find by name.
String? enclosingDeclarationName(AstNode node) {
  for (AstNode? at = node; at != null; at = at.parent) {
    if (at is ClassMember) {
      final container = at.thisOrAncestorOfType<CompilationUnitMember>();
      final type = container == null ? null : topLevelName(container);
      final member = _memberName(at);
      return type == null ? member : (member.isEmpty ? type : '$type.$member');
    }
    if (at is CompilationUnitMember) {
      return topLevelName(at);
    }
  }
  return null;
}

String _memberName(ClassMember member) => switch (member) {
  MethodDeclaration(:final name) => name.lexeme,
  ConstructorDeclaration(:final name) => name?.lexeme ?? '',
  FieldDeclaration(:final fields) => fields.variables.map((v) => v.name.lexeme).join(', '),
};
