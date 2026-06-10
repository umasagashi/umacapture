// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'addon_action.dart';

class AddonActionMapper extends ClassMapperBase<AddonAction> {
  AddonActionMapper._();

  static AddonActionMapper? _instance;
  static AddonActionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = AddonActionMapper._());
      ExternalProgramActionMapper.ensureInitialized();
      WebhookActionMapper.ensureInitialized();
      BuiltinActionMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'AddonAction';

  @override
  final MappableFields<AddonAction> fields = const {};

  static AddonAction _instantiate(DecodingData data) {
    throw MapperException.missingSubclass(
      'AddonAction',
      'kind',
      '${data.value['kind']}',
    );
  }

  @override
  final Function instantiate = _instantiate;

  static AddonAction fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<AddonAction>(map);
  }

  static AddonAction fromJson(String json) {
    return ensureInitialized().decodeJson<AddonAction>(json);
  }
}

mixin AddonActionMappable {
  String toJson();
  Map<String, dynamic> toMap();
}

class ExternalProgramActionMapper
    extends SubClassMapperBase<ExternalProgramAction> {
  ExternalProgramActionMapper._();

  static ExternalProgramActionMapper? _instance;
  static ExternalProgramActionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ExternalProgramActionMapper._());
      AddonActionMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'ExternalProgramAction';

  static String _$programPath(ExternalProgramAction v) => v.programPath;
  static const Field<ExternalProgramAction, String> _f$programPath = Field(
    'programPath',
    _$programPath,
  );
  static String _$argumentTemplate(ExternalProgramAction v) =>
      v.argumentTemplate;
  static const Field<ExternalProgramAction, String> _f$argumentTemplate = Field(
    'argumentTemplate',
    _$argumentTemplate,
    opt: true,
    def: '',
  );
  static int? _$timeoutSeconds(ExternalProgramAction v) => v.timeoutSeconds;
  static const Field<ExternalProgramAction, int> _f$timeoutSeconds = Field(
    'timeoutSeconds',
    _$timeoutSeconds,
    opt: true,
  );
  static bool _$runInShell(ExternalProgramAction v) => v.runInShell;
  static const Field<ExternalProgramAction, bool> _f$runInShell = Field(
    'runInShell',
    _$runInShell,
    opt: true,
    def: false,
  );
  static String? _$workingDirectory(ExternalProgramAction v) =>
      v.workingDirectory;
  static const Field<ExternalProgramAction, String> _f$workingDirectory = Field(
    'workingDirectory',
    _$workingDirectory,
    opt: true,
  );

  @override
  final MappableFields<ExternalProgramAction> fields = const {
    #programPath: _f$programPath,
    #argumentTemplate: _f$argumentTemplate,
    #timeoutSeconds: _f$timeoutSeconds,
    #runInShell: _f$runInShell,
    #workingDirectory: _f$workingDirectory,
  };

  @override
  final String discriminatorKey = 'kind';
  @override
  final dynamic discriminatorValue = 'ExternalProgramAction';
  @override
  late final ClassMapperBase superMapper =
      AddonActionMapper.ensureInitialized();

  static ExternalProgramAction _instantiate(DecodingData data) {
    return ExternalProgramAction(
      programPath: data.dec(_f$programPath),
      argumentTemplate: data.dec(_f$argumentTemplate),
      timeoutSeconds: data.dec(_f$timeoutSeconds),
      runInShell: data.dec(_f$runInShell),
      workingDirectory: data.dec(_f$workingDirectory),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ExternalProgramAction fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ExternalProgramAction>(map);
  }

  static ExternalProgramAction fromJson(String json) {
    return ensureInitialized().decodeJson<ExternalProgramAction>(json);
  }
}

mixin ExternalProgramActionMappable {
  String toJson() {
    return ExternalProgramActionMapper.ensureInitialized()
        .encodeJson<ExternalProgramAction>(this as ExternalProgramAction);
  }

  Map<String, dynamic> toMap() {
    return ExternalProgramActionMapper.ensureInitialized()
        .encodeMap<ExternalProgramAction>(this as ExternalProgramAction);
  }
}

class WebhookActionMapper extends SubClassMapperBase<WebhookAction> {
  WebhookActionMapper._();

  static WebhookActionMapper? _instance;
  static WebhookActionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = WebhookActionMapper._());
      AddonActionMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'WebhookAction';

  static String _$url(WebhookAction v) => v.url;
  static const Field<WebhookAction, String> _f$url = Field('url', _$url);
  static String _$method(WebhookAction v) => v.method;
  static const Field<WebhookAction, String> _f$method = Field(
    'method',
    _$method,
    opt: true,
    def: 'POST',
  );
  static String _$bodyTemplate(WebhookAction v) => v.bodyTemplate;
  static const Field<WebhookAction, String> _f$bodyTemplate = Field(
    'bodyTemplate',
    _$bodyTemplate,
    opt: true,
    def: '',
  );
  static String _$contentType(WebhookAction v) => v.contentType;
  static const Field<WebhookAction, String> _f$contentType = Field(
    'contentType',
    _$contentType,
    opt: true,
    def: 'json',
  );
  static int? _$timeoutSeconds(WebhookAction v) => v.timeoutSeconds;
  static const Field<WebhookAction, int> _f$timeoutSeconds = Field(
    'timeoutSeconds',
    _$timeoutSeconds,
    opt: true,
  );

  @override
  final MappableFields<WebhookAction> fields = const {
    #url: _f$url,
    #method: _f$method,
    #bodyTemplate: _f$bodyTemplate,
    #contentType: _f$contentType,
    #timeoutSeconds: _f$timeoutSeconds,
  };

  @override
  final String discriminatorKey = 'kind';
  @override
  final dynamic discriminatorValue = 'WebhookAction';
  @override
  late final ClassMapperBase superMapper =
      AddonActionMapper.ensureInitialized();

  static WebhookAction _instantiate(DecodingData data) {
    return WebhookAction(
      url: data.dec(_f$url),
      method: data.dec(_f$method),
      bodyTemplate: data.dec(_f$bodyTemplate),
      contentType: data.dec(_f$contentType),
      timeoutSeconds: data.dec(_f$timeoutSeconds),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static WebhookAction fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<WebhookAction>(map);
  }

  static WebhookAction fromJson(String json) {
    return ensureInitialized().decodeJson<WebhookAction>(json);
  }
}

mixin WebhookActionMappable {
  String toJson() {
    return WebhookActionMapper.ensureInitialized().encodeJson<WebhookAction>(
      this as WebhookAction,
    );
  }

  Map<String, dynamic> toMap() {
    return WebhookActionMapper.ensureInitialized().encodeMap<WebhookAction>(
      this as WebhookAction,
    );
  }
}

class BuiltinActionMapper extends SubClassMapperBase<BuiltinAction> {
  BuiltinActionMapper._();

  static BuiltinActionMapper? _instance;
  static BuiltinActionMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = BuiltinActionMapper._());
      AddonActionMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'BuiltinAction';

  static String _$actionKey(BuiltinAction v) => v.actionKey;
  static const Field<BuiltinAction, String> _f$actionKey = Field(
    'actionKey',
    _$actionKey,
  );
  static String? _$argument(BuiltinAction v) => v.argument;
  static const Field<BuiltinAction, String> _f$argument = Field(
    'argument',
    _$argument,
    opt: true,
  );

  @override
  final MappableFields<BuiltinAction> fields = const {
    #actionKey: _f$actionKey,
    #argument: _f$argument,
  };

  @override
  final String discriminatorKey = 'kind';
  @override
  final dynamic discriminatorValue = 'BuiltinAction';
  @override
  late final ClassMapperBase superMapper =
      AddonActionMapper.ensureInitialized();

  static BuiltinAction _instantiate(DecodingData data) {
    return BuiltinAction(
      actionKey: data.dec(_f$actionKey),
      argument: data.dec(_f$argument),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static BuiltinAction fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<BuiltinAction>(map);
  }

  static BuiltinAction fromJson(String json) {
    return ensureInitialized().decodeJson<BuiltinAction>(json);
  }
}

mixin BuiltinActionMappable {
  String toJson() {
    return BuiltinActionMapper.ensureInitialized().encodeJson<BuiltinAction>(
      this as BuiltinAction,
    );
  }

  Map<String, dynamic> toMap() {
    return BuiltinActionMapper.ensureInitialized().encodeMap<BuiltinAction>(
      this as BuiltinAction,
    );
  }
}

