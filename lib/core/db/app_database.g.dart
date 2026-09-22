// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SourcesTable extends Sources with TableInfo<$SourcesTable, SourceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SourcesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<MediaType, String> type =
      GeneratedColumn<String>(
        'type',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<MediaType>($SourcesTable.$convertertype);
  static const VerificationMeta _langMeta = const VerificationMeta('lang');
  @override
  late final GeneratedColumn<String> lang = GeneratedColumn<String>(
    'lang',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('zh'),
  );
  @override
  late final GeneratedColumnWithTypeConverter<SourceKind, String> kind =
      GeneratedColumn<String>(
        'kind',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<SourceKind>($SourcesTable.$converterkind);
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<String> version = GeneratedColumn<String>(
    'version',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _ruleTextMeta = const VerificationMeta(
    'ruleText',
  );
  @override
  late final GeneratedColumn<String> ruleText = GeneratedColumn<String>(
    'rule_text',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _repoUrlMeta = const VerificationMeta(
    'repoUrl',
  );
  @override
  late final GeneratedColumn<String> repoUrl = GeneratedColumn<String>(
    'repo_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    type,
    lang,
    kind,
    version,
    enabled,
    ruleText,
    repoUrl,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sources';
  @override
  VerificationContext validateIntegrity(
    Insertable<SourceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('lang')) {
      context.handle(
        _langMeta,
        lang.isAcceptableOrUnknown(data['lang']!, _langMeta),
      );
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('rule_text')) {
      context.handle(
        _ruleTextMeta,
        ruleText.isAcceptableOrUnknown(data['rule_text']!, _ruleTextMeta),
      );
    }
    if (data.containsKey('repo_url')) {
      context.handle(
        _repoUrlMeta,
        repoUrl.isAcceptableOrUnknown(data['repo_url']!, _repoUrlMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SourceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SourceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: $SourcesTable.$convertertype.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}type'],
        )!,
      ),
      lang: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lang'],
      )!,
      kind: $SourcesTable.$converterkind.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}kind'],
        )!,
      ),
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version'],
      ),
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      ruleText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rule_text'],
      ),
      repoUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}repo_url'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      ),
    );
  }

  @override
  $SourcesTable createAlias(String alias) {
    return $SourcesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MediaType, String, String> $convertertype =
      const EnumNameConverter<MediaType>(MediaType.values);
  static JsonTypeConverter2<SourceKind, String, String> $converterkind =
      const EnumNameConverter<SourceKind>(SourceKind.values);
}

class SourceRow extends DataClass implements Insertable<SourceRow> {
  /// 稳定本地标识，非站点数字 ID。
  final String id;
  final String name;

  /// 该源提供的内容形态，见 [MediaType]。
  final MediaType type;
  final String lang;

  /// 来源类型，见 [SourceKind]。
  final SourceKind kind;

  /// 扩展源版本号（内置源为 null）。
  final String? version;
  final bool enabled;

  /// 规则正文：声明式规则存 JSON，JS 扩展源存脚本源码（内置源为 null）。
  final String? ruleText;

  /// 扩展源所属仓库地址。
  final String? repoUrl;
  final DateTime? updatedAt;
  const SourceRow({
    required this.id,
    required this.name,
    required this.type,
    required this.lang,
    required this.kind,
    this.version,
    required this.enabled,
    this.ruleText,
    this.repoUrl,
    this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    {
      map['type'] = Variable<String>($SourcesTable.$convertertype.toSql(type));
    }
    map['lang'] = Variable<String>(lang);
    {
      map['kind'] = Variable<String>($SourcesTable.$converterkind.toSql(kind));
    }
    if (!nullToAbsent || version != null) {
      map['version'] = Variable<String>(version);
    }
    map['enabled'] = Variable<bool>(enabled);
    if (!nullToAbsent || ruleText != null) {
      map['rule_text'] = Variable<String>(ruleText);
    }
    if (!nullToAbsent || repoUrl != null) {
      map['repo_url'] = Variable<String>(repoUrl);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  SourcesCompanion toCompanion(bool nullToAbsent) {
    return SourcesCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      lang: Value(lang),
      kind: Value(kind),
      version: version == null && nullToAbsent
          ? const Value.absent()
          : Value(version),
      enabled: Value(enabled),
      ruleText: ruleText == null && nullToAbsent
          ? const Value.absent()
          : Value(ruleText),
      repoUrl: repoUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(repoUrl),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory SourceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SourceRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      type: $SourcesTable.$convertertype.fromJson(
        serializer.fromJson<String>(json['type']),
      ),
      lang: serializer.fromJson<String>(json['lang']),
      kind: $SourcesTable.$converterkind.fromJson(
        serializer.fromJson<String>(json['kind']),
      ),
      version: serializer.fromJson<String?>(json['version']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      ruleText: serializer.fromJson<String?>(json['ruleText']),
      repoUrl: serializer.fromJson<String?>(json['repoUrl']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(
        $SourcesTable.$convertertype.toJson(type),
      ),
      'lang': serializer.toJson<String>(lang),
      'kind': serializer.toJson<String>(
        $SourcesTable.$converterkind.toJson(kind),
      ),
      'version': serializer.toJson<String?>(version),
      'enabled': serializer.toJson<bool>(enabled),
      'ruleText': serializer.toJson<String?>(ruleText),
      'repoUrl': serializer.toJson<String?>(repoUrl),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  SourceRow copyWith({
    String? id,
    String? name,
    MediaType? type,
    String? lang,
    SourceKind? kind,
    Value<String?> version = const Value.absent(),
    bool? enabled,
    Value<String?> ruleText = const Value.absent(),
    Value<String?> repoUrl = const Value.absent(),
    Value<DateTime?> updatedAt = const Value.absent(),
  }) => SourceRow(
    id: id ?? this.id,
    name: name ?? this.name,
    type: type ?? this.type,
    lang: lang ?? this.lang,
    kind: kind ?? this.kind,
    version: version.present ? version.value : this.version,
    enabled: enabled ?? this.enabled,
    ruleText: ruleText.present ? ruleText.value : this.ruleText,
    repoUrl: repoUrl.present ? repoUrl.value : this.repoUrl,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
  );
  SourceRow copyWithCompanion(SourcesCompanion data) {
    return SourceRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      lang: data.lang.present ? data.lang.value : this.lang,
      kind: data.kind.present ? data.kind.value : this.kind,
      version: data.version.present ? data.version.value : this.version,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      ruleText: data.ruleText.present ? data.ruleText.value : this.ruleText,
      repoUrl: data.repoUrl.present ? data.repoUrl.value : this.repoUrl,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SourceRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('lang: $lang, ')
          ..write('kind: $kind, ')
          ..write('version: $version, ')
          ..write('enabled: $enabled, ')
          ..write('ruleText: $ruleText, ')
          ..write('repoUrl: $repoUrl, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    lang,
    kind,
    version,
    enabled,
    ruleText,
    repoUrl,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.type == this.type &&
          other.lang == this.lang &&
          other.kind == this.kind &&
          other.version == this.version &&
          other.enabled == this.enabled &&
          other.ruleText == this.ruleText &&
          other.repoUrl == this.repoUrl &&
          other.updatedAt == this.updatedAt);
}

class SourcesCompanion extends UpdateCompanion<SourceRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<MediaType> type;
  final Value<String> lang;
  final Value<SourceKind> kind;
  final Value<String?> version;
  final Value<bool> enabled;
  final Value<String?> ruleText;
  final Value<String?> repoUrl;
  final Value<DateTime?> updatedAt;
  final Value<int> rowid;
  const SourcesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.lang = const Value.absent(),
    this.kind = const Value.absent(),
    this.version = const Value.absent(),
    this.enabled = const Value.absent(),
    this.ruleText = const Value.absent(),
    this.repoUrl = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SourcesCompanion.insert({
    required String id,
    required String name,
    required MediaType type,
    this.lang = const Value.absent(),
    required SourceKind kind,
    this.version = const Value.absent(),
    this.enabled = const Value.absent(),
    this.ruleText = const Value.absent(),
    this.repoUrl = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       type = Value(type),
       kind = Value(kind);
  static Insertable<SourceRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? type,
    Expression<String>? lang,
    Expression<String>? kind,
    Expression<String>? version,
    Expression<bool>? enabled,
    Expression<String>? ruleText,
    Expression<String>? repoUrl,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (lang != null) 'lang': lang,
      if (kind != null) 'kind': kind,
      if (version != null) 'version': version,
      if (enabled != null) 'enabled': enabled,
      if (ruleText != null) 'rule_text': ruleText,
      if (repoUrl != null) 'repo_url': repoUrl,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SourcesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<MediaType>? type,
    Value<String>? lang,
    Value<SourceKind>? kind,
    Value<String?>? version,
    Value<bool>? enabled,
    Value<String?>? ruleText,
    Value<String?>? repoUrl,
    Value<DateTime?>? updatedAt,
    Value<int>? rowid,
  }) {
    return SourcesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      lang: lang ?? this.lang,
      kind: kind ?? this.kind,
      version: version ?? this.version,
      enabled: enabled ?? this.enabled,
      ruleText: ruleText ?? this.ruleText,
      repoUrl: repoUrl ?? this.repoUrl,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(
        $SourcesTable.$convertertype.toSql(type.value),
      );
    }
    if (lang.present) {
      map['lang'] = Variable<String>(lang.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(
        $SourcesTable.$converterkind.toSql(kind.value),
      );
    }
    if (version.present) {
      map['version'] = Variable<String>(version.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (ruleText.present) {
      map['rule_text'] = Variable<String>(ruleText.value);
    }
    if (repoUrl.present) {
      map['repo_url'] = Variable<String>(repoUrl.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SourcesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('lang: $lang, ')
          ..write('kind: $kind, ')
          ..write('version: $version, ')
          ..write('enabled: $enabled, ')
          ..write('ruleText: $ruleText, ')
          ..write('repoUrl: $repoUrl, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MediaItemsTable extends MediaItems
    with TableInfo<$MediaItemsTable, MediaItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<MediaType, String> type =
      GeneratedColumn<String>(
        'type',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<MediaType>($MediaItemsTable.$convertertype);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverUrlMeta = const VerificationMeta(
    'coverUrl',
  );
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
    'cover_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
    'author',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<double> rating = GeneratedColumn<double>(
    'rating',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _detailJsonMeta = const VerificationMeta(
    'detailJson',
  );
  @override
  late final GeneratedColumn<String> detailJson = GeneratedColumn<String>(
    'detail_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<DateTime> cachedAt = GeneratedColumn<DateTime>(
    'cached_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sourceId,
    remoteId,
    type,
    title,
    coverUrl,
    author,
    description,
    tagsJson,
    rating,
    status,
    detailJson,
    cachedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('cover_url')) {
      context.handle(
        _coverUrlMeta,
        coverUrl.isAcceptableOrUnknown(data['cover_url']!, _coverUrlMeta),
      );
    }
    if (data.containsKey('author')) {
      context.handle(
        _authorMeta,
        author.isAcceptableOrUnknown(data['author']!, _authorMeta),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    }
    if (data.containsKey('rating')) {
      context.handle(
        _ratingMeta,
        rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('detail_json')) {
      context.handle(
        _detailJsonMeta,
        detailJson.isAcceptableOrUnknown(data['detail_json']!, _detailJsonMeta),
      );
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceId, remoteId};
  @override
  MediaItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaItemRow(
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      type: $MediaItemsTable.$convertertype.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}type'],
        )!,
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      coverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_url'],
      ),
      author: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author'],
      ),
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      ),
      rating: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rating'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      ),
      detailJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}detail_json'],
      ),
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cached_at'],
      ),
    );
  }

  @override
  $MediaItemsTable createAlias(String alias) {
    return $MediaItemsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MediaType, String, String> $convertertype =
      const EnumNameConverter<MediaType>(MediaType.values);
}

class MediaItemRow extends DataClass implements Insertable<MediaItemRow> {
  final String sourceId;
  final String remoteId;
  final MediaType type;
  final String title;
  final String? coverUrl;
  final String? author;
  final String? description;

  /// 标签 / 题材，JSON 数组字符串。
  final String? tagsJson;
  final double? rating;

  /// 连载中 / 已完结 / 未知（原样保留来源文案）。
  final String? status;

  /// 详情页扩展字段（同书版本、关联推荐等），JSON。
  final String? detailJson;
  final DateTime? cachedAt;
  const MediaItemRow({
    required this.sourceId,
    required this.remoteId,
    required this.type,
    required this.title,
    this.coverUrl,
    this.author,
    this.description,
    this.tagsJson,
    this.rating,
    this.status,
    this.detailJson,
    this.cachedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    {
      map['type'] = Variable<String>(
        $MediaItemsTable.$convertertype.toSql(type),
      );
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || coverUrl != null) {
      map['cover_url'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || author != null) {
      map['author'] = Variable<String>(author);
    }
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    if (!nullToAbsent || tagsJson != null) {
      map['tags_json'] = Variable<String>(tagsJson);
    }
    if (!nullToAbsent || rating != null) {
      map['rating'] = Variable<double>(rating);
    }
    if (!nullToAbsent || status != null) {
      map['status'] = Variable<String>(status);
    }
    if (!nullToAbsent || detailJson != null) {
      map['detail_json'] = Variable<String>(detailJson);
    }
    if (!nullToAbsent || cachedAt != null) {
      map['cached_at'] = Variable<DateTime>(cachedAt);
    }
    return map;
  }

  MediaItemsCompanion toCompanion(bool nullToAbsent) {
    return MediaItemsCompanion(
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      type: Value(type),
      title: Value(title),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      author: author == null && nullToAbsent
          ? const Value.absent()
          : Value(author),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
      tagsJson: tagsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(tagsJson),
      rating: rating == null && nullToAbsent
          ? const Value.absent()
          : Value(rating),
      status: status == null && nullToAbsent
          ? const Value.absent()
          : Value(status),
      detailJson: detailJson == null && nullToAbsent
          ? const Value.absent()
          : Value(detailJson),
      cachedAt: cachedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(cachedAt),
    );
  }

  factory MediaItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaItemRow(
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      type: $MediaItemsTable.$convertertype.fromJson(
        serializer.fromJson<String>(json['type']),
      ),
      title: serializer.fromJson<String>(json['title']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      author: serializer.fromJson<String?>(json['author']),
      description: serializer.fromJson<String?>(json['description']),
      tagsJson: serializer.fromJson<String?>(json['tagsJson']),
      rating: serializer.fromJson<double?>(json['rating']),
      status: serializer.fromJson<String?>(json['status']),
      detailJson: serializer.fromJson<String?>(json['detailJson']),
      cachedAt: serializer.fromJson<DateTime?>(json['cachedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'type': serializer.toJson<String>(
        $MediaItemsTable.$convertertype.toJson(type),
      ),
      'title': serializer.toJson<String>(title),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'author': serializer.toJson<String?>(author),
      'description': serializer.toJson<String?>(description),
      'tagsJson': serializer.toJson<String?>(tagsJson),
      'rating': serializer.toJson<double?>(rating),
      'status': serializer.toJson<String?>(status),
      'detailJson': serializer.toJson<String?>(detailJson),
      'cachedAt': serializer.toJson<DateTime?>(cachedAt),
    };
  }

  MediaItemRow copyWith({
    String? sourceId,
    String? remoteId,
    MediaType? type,
    String? title,
    Value<String?> coverUrl = const Value.absent(),
    Value<String?> author = const Value.absent(),
    Value<String?> description = const Value.absent(),
    Value<String?> tagsJson = const Value.absent(),
    Value<double?> rating = const Value.absent(),
    Value<String?> status = const Value.absent(),
    Value<String?> detailJson = const Value.absent(),
    Value<DateTime?> cachedAt = const Value.absent(),
  }) => MediaItemRow(
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    type: type ?? this.type,
    title: title ?? this.title,
    coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
    author: author.present ? author.value : this.author,
    description: description.present ? description.value : this.description,
    tagsJson: tagsJson.present ? tagsJson.value : this.tagsJson,
    rating: rating.present ? rating.value : this.rating,
    status: status.present ? status.value : this.status,
    detailJson: detailJson.present ? detailJson.value : this.detailJson,
    cachedAt: cachedAt.present ? cachedAt.value : this.cachedAt,
  );
  MediaItemRow copyWithCompanion(MediaItemsCompanion data) {
    return MediaItemRow(
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      type: data.type.present ? data.type.value : this.type,
      title: data.title.present ? data.title.value : this.title,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      author: data.author.present ? data.author.value : this.author,
      description: data.description.present
          ? data.description.value
          : this.description,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      rating: data.rating.present ? data.rating.value : this.rating,
      status: data.status.present ? data.status.value : this.status,
      detailJson: data.detailJson.present
          ? data.detailJson.value
          : this.detailJson,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaItemRow(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('type: $type, ')
          ..write('title: $title, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('author: $author, ')
          ..write('description: $description, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('rating: $rating, ')
          ..write('status: $status, ')
          ..write('detailJson: $detailJson, ')
          ..write('cachedAt: $cachedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sourceId,
    remoteId,
    type,
    title,
    coverUrl,
    author,
    description,
    tagsJson,
    rating,
    status,
    detailJson,
    cachedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaItemRow &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.type == this.type &&
          other.title == this.title &&
          other.coverUrl == this.coverUrl &&
          other.author == this.author &&
          other.description == this.description &&
          other.tagsJson == this.tagsJson &&
          other.rating == this.rating &&
          other.status == this.status &&
          other.detailJson == this.detailJson &&
          other.cachedAt == this.cachedAt);
}

class MediaItemsCompanion extends UpdateCompanion<MediaItemRow> {
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<MediaType> type;
  final Value<String> title;
  final Value<String?> coverUrl;
  final Value<String?> author;
  final Value<String?> description;
  final Value<String?> tagsJson;
  final Value<double?> rating;
  final Value<String?> status;
  final Value<String?> detailJson;
  final Value<DateTime?> cachedAt;
  final Value<int> rowid;
  const MediaItemsCompanion({
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.type = const Value.absent(),
    this.title = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.author = const Value.absent(),
    this.description = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.rating = const Value.absent(),
    this.status = const Value.absent(),
    this.detailJson = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaItemsCompanion.insert({
    required String sourceId,
    required String remoteId,
    required MediaType type,
    required String title,
    this.coverUrl = const Value.absent(),
    this.author = const Value.absent(),
    this.description = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.rating = const Value.absent(),
    this.status = const Value.absent(),
    this.detailJson = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       type = Value(type),
       title = Value(title);
  static Insertable<MediaItemRow> custom({
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<String>? type,
    Expression<String>? title,
    Expression<String>? coverUrl,
    Expression<String>? author,
    Expression<String>? description,
    Expression<String>? tagsJson,
    Expression<double>? rating,
    Expression<String>? status,
    Expression<String>? detailJson,
    Expression<DateTime>? cachedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (type != null) 'type': type,
      if (title != null) 'title': title,
      if (coverUrl != null) 'cover_url': coverUrl,
      if (author != null) 'author': author,
      if (description != null) 'description': description,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (rating != null) 'rating': rating,
      if (status != null) 'status': status,
      if (detailJson != null) 'detail_json': detailJson,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaItemsCompanion copyWith({
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<MediaType>? type,
    Value<String>? title,
    Value<String?>? coverUrl,
    Value<String?>? author,
    Value<String?>? description,
    Value<String?>? tagsJson,
    Value<double?>? rating,
    Value<String?>? status,
    Value<String?>? detailJson,
    Value<DateTime?>? cachedAt,
    Value<int>? rowid,
  }) {
    return MediaItemsCompanion(
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      type: type ?? this.type,
      title: title ?? this.title,
      coverUrl: coverUrl ?? this.coverUrl,
      author: author ?? this.author,
      description: description ?? this.description,
      tagsJson: tagsJson ?? this.tagsJson,
      rating: rating ?? this.rating,
      status: status ?? this.status,
      detailJson: detailJson ?? this.detailJson,
      cachedAt: cachedAt ?? this.cachedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(
        $MediaItemsTable.$convertertype.toSql(type.value),
      );
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (coverUrl.present) {
      map['cover_url'] = Variable<String>(coverUrl.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (rating.present) {
      map['rating'] = Variable<double>(rating.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (detailJson.present) {
      map['detail_json'] = Variable<String>(detailJson.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<DateTime>(cachedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaItemsCompanion(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('type: $type, ')
          ..write('title: $title, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('author: $author, ')
          ..write('description: $description, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('rating: $rating, ')
          ..write('status: $status, ')
          ..write('detailJson: $detailJson, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChaptersTable extends Chapters
    with TableInfo<$ChaptersTable, ChapterRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChaptersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _itemSourceIdMeta = const VerificationMeta(
    'itemSourceId',
  );
  @override
  late final GeneratedColumn<String> itemSourceId = GeneratedColumn<String>(
    'item_source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _itemRemoteIdMeta = const VerificationMeta(
    'itemRemoteId',
  );
  @override
  late final GeneratedColumn<String> itemRemoteId = GeneratedColumn<String>(
    'item_remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _numberMeta = const VerificationMeta('number');
  @override
  late final GeneratedColumn<double> number = GeneratedColumn<double>(
    'number',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortIndexMeta = const VerificationMeta(
    'sortIndex',
  );
  @override
  late final GeneratedColumn<int> sortIndex = GeneratedColumn<int>(
    'sort_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _volumeTitleMeta = const VerificationMeta(
    'volumeTitle',
  );
  @override
  late final GeneratedColumn<String> volumeTitle = GeneratedColumn<String>(
    'volume_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _releaseDateMeta = const VerificationMeta(
    'releaseDate',
  );
  @override
  late final GeneratedColumn<DateTime> releaseDate = GeneratedColumn<DateTime>(
    'release_date',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lockedMeta = const VerificationMeta('locked');
  @override
  late final GeneratedColumn<bool> locked = GeneratedColumn<bool>(
    'locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _contentJsonMeta = const VerificationMeta(
    'contentJson',
  );
  @override
  late final GeneratedColumn<String> contentJson = GeneratedColumn<String>(
    'content_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sourceId,
    remoteId,
    itemSourceId,
    itemRemoteId,
    title,
    number,
    sortIndex,
    volumeTitle,
    releaseDate,
    locked,
    contentJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chapters';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChapterRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('item_source_id')) {
      context.handle(
        _itemSourceIdMeta,
        itemSourceId.isAcceptableOrUnknown(
          data['item_source_id']!,
          _itemSourceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_itemSourceIdMeta);
    }
    if (data.containsKey('item_remote_id')) {
      context.handle(
        _itemRemoteIdMeta,
        itemRemoteId.isAcceptableOrUnknown(
          data['item_remote_id']!,
          _itemRemoteIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_itemRemoteIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('number')) {
      context.handle(
        _numberMeta,
        number.isAcceptableOrUnknown(data['number']!, _numberMeta),
      );
    }
    if (data.containsKey('sort_index')) {
      context.handle(
        _sortIndexMeta,
        sortIndex.isAcceptableOrUnknown(data['sort_index']!, _sortIndexMeta),
      );
    }
    if (data.containsKey('volume_title')) {
      context.handle(
        _volumeTitleMeta,
        volumeTitle.isAcceptableOrUnknown(
          data['volume_title']!,
          _volumeTitleMeta,
        ),
      );
    }
    if (data.containsKey('release_date')) {
      context.handle(
        _releaseDateMeta,
        releaseDate.isAcceptableOrUnknown(
          data['release_date']!,
          _releaseDateMeta,
        ),
      );
    }
    if (data.containsKey('locked')) {
      context.handle(
        _lockedMeta,
        locked.isAcceptableOrUnknown(data['locked']!, _lockedMeta),
      );
    }
    if (data.containsKey('content_json')) {
      context.handle(
        _contentJsonMeta,
        contentJson.isAcceptableOrUnknown(
          data['content_json']!,
          _contentJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceId, remoteId};
  @override
  ChapterRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChapterRow(
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      itemSourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}item_source_id'],
      )!,
      itemRemoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}item_remote_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      number: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}number'],
      ),
      sortIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_index'],
      )!,
      volumeTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}volume_title'],
      ),
      releaseDate: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}release_date'],
      ),
      locked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}locked'],
      )!,
      contentJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_json'],
      ),
    );
  }

  @override
  $ChaptersTable createAlias(String alias) {
    return $ChaptersTable(attachedDatabase, alias);
  }
}

class ChapterRow extends DataClass implements Insertable<ChapterRow> {
  final String sourceId;
  final String remoteId;

  /// 所属作品的外键（复合）。
  final String itemSourceId;
  final String itemRemoteId;
  final String title;

  /// 章节号，支持 4.5 / 4.a 这类小数与字母后缀（参考 Mihon 的章节号识别）。
  final double? number;

  /// 排序用序号，避免章节号缺失时顺序错乱。
  final int sortIndex;
  final String? volumeTitle;
  final DateTime? releaseDate;

  /// 付费 / 锁定章节：只标注，不绕过、不缓存、不导出。
  final bool locked;

  /// 正文 / 图片列表 / 播放线路，JSON。
  final String? contentJson;
  const ChapterRow({
    required this.sourceId,
    required this.remoteId,
    required this.itemSourceId,
    required this.itemRemoteId,
    required this.title,
    this.number,
    required this.sortIndex,
    this.volumeTitle,
    this.releaseDate,
    required this.locked,
    this.contentJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    map['item_source_id'] = Variable<String>(itemSourceId);
    map['item_remote_id'] = Variable<String>(itemRemoteId);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || number != null) {
      map['number'] = Variable<double>(number);
    }
    map['sort_index'] = Variable<int>(sortIndex);
    if (!nullToAbsent || volumeTitle != null) {
      map['volume_title'] = Variable<String>(volumeTitle);
    }
    if (!nullToAbsent || releaseDate != null) {
      map['release_date'] = Variable<DateTime>(releaseDate);
    }
    map['locked'] = Variable<bool>(locked);
    if (!nullToAbsent || contentJson != null) {
      map['content_json'] = Variable<String>(contentJson);
    }
    return map;
  }

  ChaptersCompanion toCompanion(bool nullToAbsent) {
    return ChaptersCompanion(
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      itemSourceId: Value(itemSourceId),
      itemRemoteId: Value(itemRemoteId),
      title: Value(title),
      number: number == null && nullToAbsent
          ? const Value.absent()
          : Value(number),
      sortIndex: Value(sortIndex),
      volumeTitle: volumeTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(volumeTitle),
      releaseDate: releaseDate == null && nullToAbsent
          ? const Value.absent()
          : Value(releaseDate),
      locked: Value(locked),
      contentJson: contentJson == null && nullToAbsent
          ? const Value.absent()
          : Value(contentJson),
    );
  }

  factory ChapterRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChapterRow(
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      itemSourceId: serializer.fromJson<String>(json['itemSourceId']),
      itemRemoteId: serializer.fromJson<String>(json['itemRemoteId']),
      title: serializer.fromJson<String>(json['title']),
      number: serializer.fromJson<double?>(json['number']),
      sortIndex: serializer.fromJson<int>(json['sortIndex']),
      volumeTitle: serializer.fromJson<String?>(json['volumeTitle']),
      releaseDate: serializer.fromJson<DateTime?>(json['releaseDate']),
      locked: serializer.fromJson<bool>(json['locked']),
      contentJson: serializer.fromJson<String?>(json['contentJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'itemSourceId': serializer.toJson<String>(itemSourceId),
      'itemRemoteId': serializer.toJson<String>(itemRemoteId),
      'title': serializer.toJson<String>(title),
      'number': serializer.toJson<double?>(number),
      'sortIndex': serializer.toJson<int>(sortIndex),
      'volumeTitle': serializer.toJson<String?>(volumeTitle),
      'releaseDate': serializer.toJson<DateTime?>(releaseDate),
      'locked': serializer.toJson<bool>(locked),
      'contentJson': serializer.toJson<String?>(contentJson),
    };
  }

  ChapterRow copyWith({
    String? sourceId,
    String? remoteId,
    String? itemSourceId,
    String? itemRemoteId,
    String? title,
    Value<double?> number = const Value.absent(),
    int? sortIndex,
    Value<String?> volumeTitle = const Value.absent(),
    Value<DateTime?> releaseDate = const Value.absent(),
    bool? locked,
    Value<String?> contentJson = const Value.absent(),
  }) => ChapterRow(
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    itemSourceId: itemSourceId ?? this.itemSourceId,
    itemRemoteId: itemRemoteId ?? this.itemRemoteId,
    title: title ?? this.title,
    number: number.present ? number.value : this.number,
    sortIndex: sortIndex ?? this.sortIndex,
    volumeTitle: volumeTitle.present ? volumeTitle.value : this.volumeTitle,
    releaseDate: releaseDate.present ? releaseDate.value : this.releaseDate,
    locked: locked ?? this.locked,
    contentJson: contentJson.present ? contentJson.value : this.contentJson,
  );
  ChapterRow copyWithCompanion(ChaptersCompanion data) {
    return ChapterRow(
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      itemSourceId: data.itemSourceId.present
          ? data.itemSourceId.value
          : this.itemSourceId,
      itemRemoteId: data.itemRemoteId.present
          ? data.itemRemoteId.value
          : this.itemRemoteId,
      title: data.title.present ? data.title.value : this.title,
      number: data.number.present ? data.number.value : this.number,
      sortIndex: data.sortIndex.present ? data.sortIndex.value : this.sortIndex,
      volumeTitle: data.volumeTitle.present
          ? data.volumeTitle.value
          : this.volumeTitle,
      releaseDate: data.releaseDate.present
          ? data.releaseDate.value
          : this.releaseDate,
      locked: data.locked.present ? data.locked.value : this.locked,
      contentJson: data.contentJson.present
          ? data.contentJson.value
          : this.contentJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChapterRow(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('itemSourceId: $itemSourceId, ')
          ..write('itemRemoteId: $itemRemoteId, ')
          ..write('title: $title, ')
          ..write('number: $number, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('volumeTitle: $volumeTitle, ')
          ..write('releaseDate: $releaseDate, ')
          ..write('locked: $locked, ')
          ..write('contentJson: $contentJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sourceId,
    remoteId,
    itemSourceId,
    itemRemoteId,
    title,
    number,
    sortIndex,
    volumeTitle,
    releaseDate,
    locked,
    contentJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChapterRow &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.itemSourceId == this.itemSourceId &&
          other.itemRemoteId == this.itemRemoteId &&
          other.title == this.title &&
          other.number == this.number &&
          other.sortIndex == this.sortIndex &&
          other.volumeTitle == this.volumeTitle &&
          other.releaseDate == this.releaseDate &&
          other.locked == this.locked &&
          other.contentJson == this.contentJson);
}

class ChaptersCompanion extends UpdateCompanion<ChapterRow> {
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<String> itemSourceId;
  final Value<String> itemRemoteId;
  final Value<String> title;
  final Value<double?> number;
  final Value<int> sortIndex;
  final Value<String?> volumeTitle;
  final Value<DateTime?> releaseDate;
  final Value<bool> locked;
  final Value<String?> contentJson;
  final Value<int> rowid;
  const ChaptersCompanion({
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.itemSourceId = const Value.absent(),
    this.itemRemoteId = const Value.absent(),
    this.title = const Value.absent(),
    this.number = const Value.absent(),
    this.sortIndex = const Value.absent(),
    this.volumeTitle = const Value.absent(),
    this.releaseDate = const Value.absent(),
    this.locked = const Value.absent(),
    this.contentJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChaptersCompanion.insert({
    required String sourceId,
    required String remoteId,
    required String itemSourceId,
    required String itemRemoteId,
    required String title,
    this.number = const Value.absent(),
    this.sortIndex = const Value.absent(),
    this.volumeTitle = const Value.absent(),
    this.releaseDate = const Value.absent(),
    this.locked = const Value.absent(),
    this.contentJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       itemSourceId = Value(itemSourceId),
       itemRemoteId = Value(itemRemoteId),
       title = Value(title);
  static Insertable<ChapterRow> custom({
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<String>? itemSourceId,
    Expression<String>? itemRemoteId,
    Expression<String>? title,
    Expression<double>? number,
    Expression<int>? sortIndex,
    Expression<String>? volumeTitle,
    Expression<DateTime>? releaseDate,
    Expression<bool>? locked,
    Expression<String>? contentJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (itemSourceId != null) 'item_source_id': itemSourceId,
      if (itemRemoteId != null) 'item_remote_id': itemRemoteId,
      if (title != null) 'title': title,
      if (number != null) 'number': number,
      if (sortIndex != null) 'sort_index': sortIndex,
      if (volumeTitle != null) 'volume_title': volumeTitle,
      if (releaseDate != null) 'release_date': releaseDate,
      if (locked != null) 'locked': locked,
      if (contentJson != null) 'content_json': contentJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChaptersCompanion copyWith({
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<String>? itemSourceId,
    Value<String>? itemRemoteId,
    Value<String>? title,
    Value<double?>? number,
    Value<int>? sortIndex,
    Value<String?>? volumeTitle,
    Value<DateTime?>? releaseDate,
    Value<bool>? locked,
    Value<String?>? contentJson,
    Value<int>? rowid,
  }) {
    return ChaptersCompanion(
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      itemSourceId: itemSourceId ?? this.itemSourceId,
      itemRemoteId: itemRemoteId ?? this.itemRemoteId,
      title: title ?? this.title,
      number: number ?? this.number,
      sortIndex: sortIndex ?? this.sortIndex,
      volumeTitle: volumeTitle ?? this.volumeTitle,
      releaseDate: releaseDate ?? this.releaseDate,
      locked: locked ?? this.locked,
      contentJson: contentJson ?? this.contentJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (itemSourceId.present) {
      map['item_source_id'] = Variable<String>(itemSourceId.value);
    }
    if (itemRemoteId.present) {
      map['item_remote_id'] = Variable<String>(itemRemoteId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (number.present) {
      map['number'] = Variable<double>(number.value);
    }
    if (sortIndex.present) {
      map['sort_index'] = Variable<int>(sortIndex.value);
    }
    if (volumeTitle.present) {
      map['volume_title'] = Variable<String>(volumeTitle.value);
    }
    if (releaseDate.present) {
      map['release_date'] = Variable<DateTime>(releaseDate.value);
    }
    if (locked.present) {
      map['locked'] = Variable<bool>(locked.value);
    }
    if (contentJson.present) {
      map['content_json'] = Variable<String>(contentJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChaptersCompanion(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('itemSourceId: $itemSourceId, ')
          ..write('itemRemoteId: $itemRemoteId, ')
          ..write('title: $title, ')
          ..write('number: $number, ')
          ..write('sortIndex: $sortIndex, ')
          ..write('volumeTitle: $volumeTitle, ')
          ..write('releaseDate: $releaseDate, ')
          ..write('locked: $locked, ')
          ..write('contentJson: $contentJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryEntriesTable extends LibraryEntries
    with TableInfo<$LibraryEntriesTable, LibraryEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<MediaType, String> type =
      GeneratedColumn<String>(
        'type',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<MediaType>($LibraryEntriesTable.$convertertype);
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<double> progress = GeneratedColumn<double>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant<double>(0),
  );
  static const VerificationMeta _scoreMeta = const VerificationMeta('score');
  @override
  late final GeneratedColumn<int> score = GeneratedColumn<int>(
    'score',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('doing'),
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _unreadCountMeta = const VerificationMeta(
    'unreadCount',
  );
  @override
  late final GeneratedColumn<int> unreadCount = GeneratedColumn<int>(
    'unread_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sourceId,
    remoteId,
    type,
    progress,
    score,
    status,
    pinned,
    unreadCount,
    addedAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    }
    if (data.containsKey('score')) {
      context.handle(
        _scoreMeta,
        score.isAcceptableOrUnknown(data['score']!, _scoreMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    if (data.containsKey('unread_count')) {
      context.handle(
        _unreadCountMeta,
        unreadCount.isAcceptableOrUnknown(
          data['unread_count']!,
          _unreadCountMeta,
        ),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceId, remoteId};
  @override
  LibraryEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryEntryRow(
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      type: $LibraryEntriesTable.$convertertype.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}type'],
        )!,
      ),
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}progress'],
      )!,
      score: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}score'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned'],
      )!,
      unreadCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_count'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}added_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LibraryEntriesTable createAlias(String alias) {
    return $LibraryEntriesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MediaType, String, String> $convertertype =
      const EnumNameConverter<MediaType>(MediaType.values);
}

class LibraryEntryRow extends DataClass implements Insertable<LibraryEntryRow> {
  final String sourceId;
  final String remoteId;
  final MediaType type;

  /// 看到第几章（番剧为集数）。
  final double progress;

  /// 用户评分（0~10，未评为 null）。
  final int? score;

  /// 在看 / 想看 / 看过 / 搁置 / 抛弃（对齐 Bangumi 五态）。
  final String status;
  final bool pinned;

  /// 来源报告的未读/新增章数（LK 有此能力，其他源靠刷新对比）。
  final int unreadCount;
  final DateTime addedAt;
  final DateTime updatedAt;
  const LibraryEntryRow({
    required this.sourceId,
    required this.remoteId,
    required this.type,
    required this.progress,
    this.score,
    required this.status,
    required this.pinned,
    required this.unreadCount,
    required this.addedAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    {
      map['type'] = Variable<String>(
        $LibraryEntriesTable.$convertertype.toSql(type),
      );
    }
    map['progress'] = Variable<double>(progress);
    if (!nullToAbsent || score != null) {
      map['score'] = Variable<int>(score);
    }
    map['status'] = Variable<String>(status);
    map['pinned'] = Variable<bool>(pinned);
    map['unread_count'] = Variable<int>(unreadCount);
    map['added_at'] = Variable<DateTime>(addedAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LibraryEntriesCompanion toCompanion(bool nullToAbsent) {
    return LibraryEntriesCompanion(
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      type: Value(type),
      progress: Value(progress),
      score: score == null && nullToAbsent
          ? const Value.absent()
          : Value(score),
      status: Value(status),
      pinned: Value(pinned),
      unreadCount: Value(unreadCount),
      addedAt: Value(addedAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory LibraryEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryEntryRow(
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      type: $LibraryEntriesTable.$convertertype.fromJson(
        serializer.fromJson<String>(json['type']),
      ),
      progress: serializer.fromJson<double>(json['progress']),
      score: serializer.fromJson<int?>(json['score']),
      status: serializer.fromJson<String>(json['status']),
      pinned: serializer.fromJson<bool>(json['pinned']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'type': serializer.toJson<String>(
        $LibraryEntriesTable.$convertertype.toJson(type),
      ),
      'progress': serializer.toJson<double>(progress),
      'score': serializer.toJson<int?>(score),
      'status': serializer.toJson<String>(status),
      'pinned': serializer.toJson<bool>(pinned),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'addedAt': serializer.toJson<DateTime>(addedAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  LibraryEntryRow copyWith({
    String? sourceId,
    String? remoteId,
    MediaType? type,
    double? progress,
    Value<int?> score = const Value.absent(),
    String? status,
    bool? pinned,
    int? unreadCount,
    DateTime? addedAt,
    DateTime? updatedAt,
  }) => LibraryEntryRow(
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    type: type ?? this.type,
    progress: progress ?? this.progress,
    score: score.present ? score.value : this.score,
    status: status ?? this.status,
    pinned: pinned ?? this.pinned,
    unreadCount: unreadCount ?? this.unreadCount,
    addedAt: addedAt ?? this.addedAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LibraryEntryRow copyWithCompanion(LibraryEntriesCompanion data) {
    return LibraryEntryRow(
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      type: data.type.present ? data.type.value : this.type,
      progress: data.progress.present ? data.progress.value : this.progress,
      score: data.score.present ? data.score.value : this.score,
      status: data.status.present ? data.status.value : this.status,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
      unreadCount: data.unreadCount.present
          ? data.unreadCount.value
          : this.unreadCount,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryEntryRow(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('type: $type, ')
          ..write('progress: $progress, ')
          ..write('score: $score, ')
          ..write('status: $status, ')
          ..write('pinned: $pinned, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('addedAt: $addedAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sourceId,
    remoteId,
    type,
    progress,
    score,
    status,
    pinned,
    unreadCount,
    addedAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryEntryRow &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.type == this.type &&
          other.progress == this.progress &&
          other.score == this.score &&
          other.status == this.status &&
          other.pinned == this.pinned &&
          other.unreadCount == this.unreadCount &&
          other.addedAt == this.addedAt &&
          other.updatedAt == this.updatedAt);
}

class LibraryEntriesCompanion extends UpdateCompanion<LibraryEntryRow> {
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<MediaType> type;
  final Value<double> progress;
  final Value<int?> score;
  final Value<String> status;
  final Value<bool> pinned;
  final Value<int> unreadCount;
  final Value<DateTime> addedAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const LibraryEntriesCompanion({
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.type = const Value.absent(),
    this.progress = const Value.absent(),
    this.score = const Value.absent(),
    this.status = const Value.absent(),
    this.pinned = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryEntriesCompanion.insert({
    required String sourceId,
    required String remoteId,
    required MediaType type,
    this.progress = const Value.absent(),
    this.score = const Value.absent(),
    this.status = const Value.absent(),
    this.pinned = const Value.absent(),
    this.unreadCount = const Value.absent(),
    required DateTime addedAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       type = Value(type),
       addedAt = Value(addedAt),
       updatedAt = Value(updatedAt);
  static Insertable<LibraryEntryRow> custom({
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<String>? type,
    Expression<double>? progress,
    Expression<int>? score,
    Expression<String>? status,
    Expression<bool>? pinned,
    Expression<int>? unreadCount,
    Expression<DateTime>? addedAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (type != null) 'type': type,
      if (progress != null) 'progress': progress,
      if (score != null) 'score': score,
      if (status != null) 'status': status,
      if (pinned != null) 'pinned': pinned,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (addedAt != null) 'added_at': addedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryEntriesCompanion copyWith({
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<MediaType>? type,
    Value<double>? progress,
    Value<int?>? score,
    Value<String>? status,
    Value<bool>? pinned,
    Value<int>? unreadCount,
    Value<DateTime>? addedAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return LibraryEntriesCompanion(
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      type: type ?? this.type,
      progress: progress ?? this.progress,
      score: score ?? this.score,
      status: status ?? this.status,
      pinned: pinned ?? this.pinned,
      unreadCount: unreadCount ?? this.unreadCount,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(
        $LibraryEntriesTable.$convertertype.toSql(type.value),
      );
    }
    if (progress.present) {
      map['progress'] = Variable<double>(progress.value);
    }
    if (score.present) {
      map['score'] = Variable<int>(score.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (unreadCount.present) {
      map['unread_count'] = Variable<int>(unreadCount.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryEntriesCompanion(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('type: $type, ')
          ..write('progress: $progress, ')
          ..write('score: $score, ')
          ..write('status: $status, ')
          ..write('pinned: $pinned, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('addedAt: $addedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CategoriesTable extends Categories
    with TableInfo<$CategoriesTable, CategoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CategoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortIndexMeta = const VerificationMeta(
    'sortIndex',
  );
  @override
  late final GeneratedColumn<int> sortIndex = GeneratedColumn<int>(
    'sort_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, sortIndex];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'categories';
  @override
  VerificationContext validateIntegrity(
    Insertable<CategoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sort_index')) {
      context.handle(
        _sortIndexMeta,
        sortIndex.isAcceptableOrUnknown(data['sort_index']!, _sortIndexMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CategoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CategoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sortIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_index'],
      )!,
    );
  }

  @override
  $CategoriesTable createAlias(String alias) {
    return $CategoriesTable(attachedDatabase, alias);
  }
}

class CategoryRow extends DataClass implements Insertable<CategoryRow> {
  final int id;
  final String name;
  final int sortIndex;
  const CategoryRow({
    required this.id,
    required this.name,
    required this.sortIndex,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['sort_index'] = Variable<int>(sortIndex);
    return map;
  }

  CategoriesCompanion toCompanion(bool nullToAbsent) {
    return CategoriesCompanion(
      id: Value(id),
      name: Value(name),
      sortIndex: Value(sortIndex),
    );
  }

  factory CategoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CategoryRow(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      sortIndex: serializer.fromJson<int>(json['sortIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'sortIndex': serializer.toJson<int>(sortIndex),
    };
  }

  CategoryRow copyWith({int? id, String? name, int? sortIndex}) => CategoryRow(
    id: id ?? this.id,
    name: name ?? this.name,
    sortIndex: sortIndex ?? this.sortIndex,
  );
  CategoryRow copyWithCompanion(CategoriesCompanion data) {
    return CategoryRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      sortIndex: data.sortIndex.present ? data.sortIndex.value : this.sortIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CategoryRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('sortIndex: $sortIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, sortIndex);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CategoryRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.sortIndex == this.sortIndex);
}

class CategoriesCompanion extends UpdateCompanion<CategoryRow> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> sortIndex;
  const CategoriesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.sortIndex = const Value.absent(),
  });
  CategoriesCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.sortIndex = const Value.absent(),
  }) : name = Value(name);
  static Insertable<CategoryRow> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? sortIndex,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (sortIndex != null) 'sort_index': sortIndex,
    });
  }

  CategoriesCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<int>? sortIndex,
  }) {
    return CategoriesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      sortIndex: sortIndex ?? this.sortIndex,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sortIndex.present) {
      map['sort_index'] = Variable<int>(sortIndex.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CategoriesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('sortIndex: $sortIndex')
          ..write(')'))
        .toString();
  }
}

class $LibraryCategoryLinksTable extends LibraryCategoryLinks
    with TableInfo<$LibraryCategoryLinksTable, LibraryCategoryLinkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryCategoryLinksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _categoryIdMeta = const VerificationMeta(
    'categoryId',
  );
  @override
  late final GeneratedColumn<int> categoryId = GeneratedColumn<int>(
    'category_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [sourceId, remoteId, categoryId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_category_links';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryCategoryLinkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('category_id')) {
      context.handle(
        _categoryIdMeta,
        categoryId.isAcceptableOrUnknown(data['category_id']!, _categoryIdMeta),
      );
    } else if (isInserting) {
      context.missing(_categoryIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceId, remoteId, categoryId};
  @override
  LibraryCategoryLinkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryCategoryLinkRow(
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      categoryId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}category_id'],
      )!,
    );
  }

  @override
  $LibraryCategoryLinksTable createAlias(String alias) {
    return $LibraryCategoryLinksTable(attachedDatabase, alias);
  }
}

class LibraryCategoryLinkRow extends DataClass
    implements Insertable<LibraryCategoryLinkRow> {
  final String sourceId;
  final String remoteId;
  final int categoryId;
  const LibraryCategoryLinkRow({
    required this.sourceId,
    required this.remoteId,
    required this.categoryId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    map['category_id'] = Variable<int>(categoryId);
    return map;
  }

  LibraryCategoryLinksCompanion toCompanion(bool nullToAbsent) {
    return LibraryCategoryLinksCompanion(
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      categoryId: Value(categoryId),
    );
  }

  factory LibraryCategoryLinkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryCategoryLinkRow(
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      categoryId: serializer.fromJson<int>(json['categoryId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'categoryId': serializer.toJson<int>(categoryId),
    };
  }

  LibraryCategoryLinkRow copyWith({
    String? sourceId,
    String? remoteId,
    int? categoryId,
  }) => LibraryCategoryLinkRow(
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    categoryId: categoryId ?? this.categoryId,
  );
  LibraryCategoryLinkRow copyWithCompanion(LibraryCategoryLinksCompanion data) {
    return LibraryCategoryLinkRow(
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      categoryId: data.categoryId.present
          ? data.categoryId.value
          : this.categoryId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryCategoryLinkRow(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('categoryId: $categoryId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sourceId, remoteId, categoryId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryCategoryLinkRow &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.categoryId == this.categoryId);
}

class LibraryCategoryLinksCompanion
    extends UpdateCompanion<LibraryCategoryLinkRow> {
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<int> categoryId;
  final Value<int> rowid;
  const LibraryCategoryLinksCompanion({
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.categoryId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryCategoryLinksCompanion.insert({
    required String sourceId,
    required String remoteId,
    required int categoryId,
    this.rowid = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       categoryId = Value(categoryId);
  static Insertable<LibraryCategoryLinkRow> custom({
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<int>? categoryId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (categoryId != null) 'category_id': categoryId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryCategoryLinksCompanion copyWith({
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<int>? categoryId,
    Value<int>? rowid,
  }) {
    return LibraryCategoryLinksCompanion(
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      categoryId: categoryId ?? this.categoryId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (categoryId.present) {
      map['category_id'] = Variable<int>(categoryId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryCategoryLinksCompanion(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('categoryId: $categoryId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HistoriesTable extends Histories
    with TableInfo<$HistoriesTable, HistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chapterSourceIdMeta = const VerificationMeta(
    'chapterSourceId',
  );
  @override
  late final GeneratedColumn<String> chapterSourceId = GeneratedColumn<String>(
    'chapter_source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chapterRemoteIdMeta = const VerificationMeta(
    'chapterRemoteId',
  );
  @override
  late final GeneratedColumn<String> chapterRemoteId = GeneratedColumn<String>(
    'chapter_remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<double> position = GeneratedColumn<double>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant<double>(0),
  );
  static const VerificationMeta _deviceMeta = const VerificationMeta('device');
  @override
  late final GeneratedColumn<String> device = GeneratedColumn<String>(
    'device',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _visitedAtMeta = const VerificationMeta(
    'visitedAt',
  );
  @override
  late final GeneratedColumn<DateTime> visitedAt = GeneratedColumn<DateTime>(
    'visited_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _incognitoMeta = const VerificationMeta(
    'incognito',
  );
  @override
  late final GeneratedColumn<bool> incognito = GeneratedColumn<bool>(
    'incognito',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("incognito" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sourceId,
    remoteId,
    chapterSourceId,
    chapterRemoteId,
    position,
    device,
    visitedAt,
    incognito,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'histories';
  @override
  VerificationContext validateIntegrity(
    Insertable<HistoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('chapter_source_id')) {
      context.handle(
        _chapterSourceIdMeta,
        chapterSourceId.isAcceptableOrUnknown(
          data['chapter_source_id']!,
          _chapterSourceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chapterSourceIdMeta);
    }
    if (data.containsKey('chapter_remote_id')) {
      context.handle(
        _chapterRemoteIdMeta,
        chapterRemoteId.isAcceptableOrUnknown(
          data['chapter_remote_id']!,
          _chapterRemoteIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chapterRemoteIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    }
    if (data.containsKey('device')) {
      context.handle(
        _deviceMeta,
        device.isAcceptableOrUnknown(data['device']!, _deviceMeta),
      );
    }
    if (data.containsKey('visited_at')) {
      context.handle(
        _visitedAtMeta,
        visitedAt.isAcceptableOrUnknown(data['visited_at']!, _visitedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_visitedAtMeta);
    }
    if (data.containsKey('incognito')) {
      context.handle(
        _incognitoMeta,
        incognito.isAcceptableOrUnknown(data['incognito']!, _incognitoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      chapterSourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_source_id'],
      )!,
      chapterRemoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_remote_id'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}position'],
      )!,
      device: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device'],
      ),
      visitedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}visited_at'],
      )!,
      incognito: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}incognito'],
      )!,
    );
  }

  @override
  $HistoriesTable createAlias(String alias) {
    return $HistoriesTable(attachedDatabase, alias);
  }
}

class HistoryRow extends DataClass implements Insertable<HistoryRow> {
  final int id;
  final String sourceId;
  final String remoteId;
  final String chapterSourceId;
  final String chapterRemoteId;

  /// 位置：番剧为秒，漫画为页，小说为段落偏移。
  final double position;

  /// 产生该记录的设备标识（多设备同步时用于冲突判断）。
  final String? device;
  final DateTime visitedAt;

  /// 无痕模式产生的记录不参与同步。
  final bool incognito;
  const HistoryRow({
    required this.id,
    required this.sourceId,
    required this.remoteId,
    required this.chapterSourceId,
    required this.chapterRemoteId,
    required this.position,
    this.device,
    required this.visitedAt,
    required this.incognito,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    map['chapter_source_id'] = Variable<String>(chapterSourceId);
    map['chapter_remote_id'] = Variable<String>(chapterRemoteId);
    map['position'] = Variable<double>(position);
    if (!nullToAbsent || device != null) {
      map['device'] = Variable<String>(device);
    }
    map['visited_at'] = Variable<DateTime>(visitedAt);
    map['incognito'] = Variable<bool>(incognito);
    return map;
  }

  HistoriesCompanion toCompanion(bool nullToAbsent) {
    return HistoriesCompanion(
      id: Value(id),
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      chapterSourceId: Value(chapterSourceId),
      chapterRemoteId: Value(chapterRemoteId),
      position: Value(position),
      device: device == null && nullToAbsent
          ? const Value.absent()
          : Value(device),
      visitedAt: Value(visitedAt),
      incognito: Value(incognito),
    );
  }

  factory HistoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryRow(
      id: serializer.fromJson<int>(json['id']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      chapterSourceId: serializer.fromJson<String>(json['chapterSourceId']),
      chapterRemoteId: serializer.fromJson<String>(json['chapterRemoteId']),
      position: serializer.fromJson<double>(json['position']),
      device: serializer.fromJson<String?>(json['device']),
      visitedAt: serializer.fromJson<DateTime>(json['visitedAt']),
      incognito: serializer.fromJson<bool>(json['incognito']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'chapterSourceId': serializer.toJson<String>(chapterSourceId),
      'chapterRemoteId': serializer.toJson<String>(chapterRemoteId),
      'position': serializer.toJson<double>(position),
      'device': serializer.toJson<String?>(device),
      'visitedAt': serializer.toJson<DateTime>(visitedAt),
      'incognito': serializer.toJson<bool>(incognito),
    };
  }

  HistoryRow copyWith({
    int? id,
    String? sourceId,
    String? remoteId,
    String? chapterSourceId,
    String? chapterRemoteId,
    double? position,
    Value<String?> device = const Value.absent(),
    DateTime? visitedAt,
    bool? incognito,
  }) => HistoryRow(
    id: id ?? this.id,
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    chapterSourceId: chapterSourceId ?? this.chapterSourceId,
    chapterRemoteId: chapterRemoteId ?? this.chapterRemoteId,
    position: position ?? this.position,
    device: device.present ? device.value : this.device,
    visitedAt: visitedAt ?? this.visitedAt,
    incognito: incognito ?? this.incognito,
  );
  HistoryRow copyWithCompanion(HistoriesCompanion data) {
    return HistoryRow(
      id: data.id.present ? data.id.value : this.id,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      chapterSourceId: data.chapterSourceId.present
          ? data.chapterSourceId.value
          : this.chapterSourceId,
      chapterRemoteId: data.chapterRemoteId.present
          ? data.chapterRemoteId.value
          : this.chapterRemoteId,
      position: data.position.present ? data.position.value : this.position,
      device: data.device.present ? data.device.value : this.device,
      visitedAt: data.visitedAt.present ? data.visitedAt.value : this.visitedAt,
      incognito: data.incognito.present ? data.incognito.value : this.incognito,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryRow(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('chapterSourceId: $chapterSourceId, ')
          ..write('chapterRemoteId: $chapterRemoteId, ')
          ..write('position: $position, ')
          ..write('device: $device, ')
          ..write('visitedAt: $visitedAt, ')
          ..write('incognito: $incognito')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourceId,
    remoteId,
    chapterSourceId,
    chapterRemoteId,
    position,
    device,
    visitedAt,
    incognito,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryRow &&
          other.id == this.id &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.chapterSourceId == this.chapterSourceId &&
          other.chapterRemoteId == this.chapterRemoteId &&
          other.position == this.position &&
          other.device == this.device &&
          other.visitedAt == this.visitedAt &&
          other.incognito == this.incognito);
}

class HistoriesCompanion extends UpdateCompanion<HistoryRow> {
  final Value<int> id;
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<String> chapterSourceId;
  final Value<String> chapterRemoteId;
  final Value<double> position;
  final Value<String?> device;
  final Value<DateTime> visitedAt;
  final Value<bool> incognito;
  const HistoriesCompanion({
    this.id = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.chapterSourceId = const Value.absent(),
    this.chapterRemoteId = const Value.absent(),
    this.position = const Value.absent(),
    this.device = const Value.absent(),
    this.visitedAt = const Value.absent(),
    this.incognito = const Value.absent(),
  });
  HistoriesCompanion.insert({
    this.id = const Value.absent(),
    required String sourceId,
    required String remoteId,
    required String chapterSourceId,
    required String chapterRemoteId,
    this.position = const Value.absent(),
    this.device = const Value.absent(),
    required DateTime visitedAt,
    this.incognito = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       chapterSourceId = Value(chapterSourceId),
       chapterRemoteId = Value(chapterRemoteId),
       visitedAt = Value(visitedAt);
  static Insertable<HistoryRow> custom({
    Expression<int>? id,
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<String>? chapterSourceId,
    Expression<String>? chapterRemoteId,
    Expression<double>? position,
    Expression<String>? device,
    Expression<DateTime>? visitedAt,
    Expression<bool>? incognito,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (chapterSourceId != null) 'chapter_source_id': chapterSourceId,
      if (chapterRemoteId != null) 'chapter_remote_id': chapterRemoteId,
      if (position != null) 'position': position,
      if (device != null) 'device': device,
      if (visitedAt != null) 'visited_at': visitedAt,
      if (incognito != null) 'incognito': incognito,
    });
  }

  HistoriesCompanion copyWith({
    Value<int>? id,
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<String>? chapterSourceId,
    Value<String>? chapterRemoteId,
    Value<double>? position,
    Value<String?>? device,
    Value<DateTime>? visitedAt,
    Value<bool>? incognito,
  }) {
    return HistoriesCompanion(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      chapterSourceId: chapterSourceId ?? this.chapterSourceId,
      chapterRemoteId: chapterRemoteId ?? this.chapterRemoteId,
      position: position ?? this.position,
      device: device ?? this.device,
      visitedAt: visitedAt ?? this.visitedAt,
      incognito: incognito ?? this.incognito,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (chapterSourceId.present) {
      map['chapter_source_id'] = Variable<String>(chapterSourceId.value);
    }
    if (chapterRemoteId.present) {
      map['chapter_remote_id'] = Variable<String>(chapterRemoteId.value);
    }
    if (position.present) {
      map['position'] = Variable<double>(position.value);
    }
    if (device.present) {
      map['device'] = Variable<String>(device.value);
    }
    if (visitedAt.present) {
      map['visited_at'] = Variable<DateTime>(visitedAt.value);
    }
    if (incognito.present) {
      map['incognito'] = Variable<bool>(incognito.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoriesCompanion(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('chapterSourceId: $chapterSourceId, ')
          ..write('chapterRemoteId: $chapterRemoteId, ')
          ..write('position: $position, ')
          ..write('device: $device, ')
          ..write('visitedAt: $visitedAt, ')
          ..write('incognito: $incognito')
          ..write(')'))
        .toString();
  }
}

class $DownloadsTable extends Downloads
    with TableInfo<$DownloadsTable, DownloadRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chapterSourceIdMeta = const VerificationMeta(
    'chapterSourceId',
  );
  @override
  late final GeneratedColumn<String> chapterSourceId = GeneratedColumn<String>(
    'chapter_source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chapterRemoteIdMeta = const VerificationMeta(
    'chapterRemoteId',
  );
  @override
  late final GeneratedColumn<String> chapterRemoteId = GeneratedColumn<String>(
    'chapter_remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<double> progress = GeneratedColumn<double>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant<double>(0),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _errorMessageMeta = const VerificationMeta(
    'errorMessage',
  );
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
    'error_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<DateTime> finishedAt = GeneratedColumn<DateTime>(
    'finished_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sourceId,
    remoteId,
    chapterSourceId,
    chapterRemoteId,
    status,
    progress,
    path,
    errorMessage,
    createdAt,
    finishedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'downloads';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('chapter_source_id')) {
      context.handle(
        _chapterSourceIdMeta,
        chapterSourceId.isAcceptableOrUnknown(
          data['chapter_source_id']!,
          _chapterSourceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chapterSourceIdMeta);
    }
    if (data.containsKey('chapter_remote_id')) {
      context.handle(
        _chapterRemoteIdMeta,
        chapterRemoteId.isAcceptableOrUnknown(
          data['chapter_remote_id']!,
          _chapterRemoteIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chapterRemoteIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    }
    if (data.containsKey('error_message')) {
      context.handle(
        _errorMessageMeta,
        errorMessage.isAcceptableOrUnknown(
          data['error_message']!,
          _errorMessageMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      chapterSourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_source_id'],
      )!,
      chapterRemoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}chapter_remote_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}progress'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      ),
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}finished_at'],
      ),
    );
  }

  @override
  $DownloadsTable createAlias(String alias) {
    return $DownloadsTable(attachedDatabase, alias);
  }
}

class DownloadRow extends DataClass implements Insertable<DownloadRow> {
  final int id;
  final String sourceId;
  final String remoteId;
  final String chapterSourceId;
  final String chapterRemoteId;

  /// queued / running / done / failed。
  final String status;
  final double progress;
  final String? path;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? finishedAt;
  const DownloadRow({
    required this.id,
    required this.sourceId,
    required this.remoteId,
    required this.chapterSourceId,
    required this.chapterRemoteId,
    required this.status,
    required this.progress,
    this.path,
    this.errorMessage,
    required this.createdAt,
    this.finishedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    map['chapter_source_id'] = Variable<String>(chapterSourceId);
    map['chapter_remote_id'] = Variable<String>(chapterRemoteId);
    map['status'] = Variable<String>(status);
    map['progress'] = Variable<double>(progress);
    if (!nullToAbsent || path != null) {
      map['path'] = Variable<String>(path);
    }
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || finishedAt != null) {
      map['finished_at'] = Variable<DateTime>(finishedAt);
    }
    return map;
  }

  DownloadsCompanion toCompanion(bool nullToAbsent) {
    return DownloadsCompanion(
      id: Value(id),
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      chapterSourceId: Value(chapterSourceId),
      chapterRemoteId: Value(chapterRemoteId),
      status: Value(status),
      progress: Value(progress),
      path: path == null && nullToAbsent ? const Value.absent() : Value(path),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      createdAt: Value(createdAt),
      finishedAt: finishedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(finishedAt),
    );
  }

  factory DownloadRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadRow(
      id: serializer.fromJson<int>(json['id']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      chapterSourceId: serializer.fromJson<String>(json['chapterSourceId']),
      chapterRemoteId: serializer.fromJson<String>(json['chapterRemoteId']),
      status: serializer.fromJson<String>(json['status']),
      progress: serializer.fromJson<double>(json['progress']),
      path: serializer.fromJson<String?>(json['path']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      finishedAt: serializer.fromJson<DateTime?>(json['finishedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'chapterSourceId': serializer.toJson<String>(chapterSourceId),
      'chapterRemoteId': serializer.toJson<String>(chapterRemoteId),
      'status': serializer.toJson<String>(status),
      'progress': serializer.toJson<double>(progress),
      'path': serializer.toJson<String?>(path),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'finishedAt': serializer.toJson<DateTime?>(finishedAt),
    };
  }

  DownloadRow copyWith({
    int? id,
    String? sourceId,
    String? remoteId,
    String? chapterSourceId,
    String? chapterRemoteId,
    String? status,
    double? progress,
    Value<String?> path = const Value.absent(),
    Value<String?> errorMessage = const Value.absent(),
    DateTime? createdAt,
    Value<DateTime?> finishedAt = const Value.absent(),
  }) => DownloadRow(
    id: id ?? this.id,
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    chapterSourceId: chapterSourceId ?? this.chapterSourceId,
    chapterRemoteId: chapterRemoteId ?? this.chapterRemoteId,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    path: path.present ? path.value : this.path,
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
    createdAt: createdAt ?? this.createdAt,
    finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
  );
  DownloadRow copyWithCompanion(DownloadsCompanion data) {
    return DownloadRow(
      id: data.id.present ? data.id.value : this.id,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      chapterSourceId: data.chapterSourceId.present
          ? data.chapterSourceId.value
          : this.chapterSourceId,
      chapterRemoteId: data.chapterRemoteId.present
          ? data.chapterRemoteId.value
          : this.chapterRemoteId,
      status: data.status.present ? data.status.value : this.status,
      progress: data.progress.present ? data.progress.value : this.progress,
      path: data.path.present ? data.path.value : this.path,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadRow(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('chapterSourceId: $chapterSourceId, ')
          ..write('chapterRemoteId: $chapterRemoteId, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('path: $path, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('createdAt: $createdAt, ')
          ..write('finishedAt: $finishedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourceId,
    remoteId,
    chapterSourceId,
    chapterRemoteId,
    status,
    progress,
    path,
    errorMessage,
    createdAt,
    finishedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadRow &&
          other.id == this.id &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.chapterSourceId == this.chapterSourceId &&
          other.chapterRemoteId == this.chapterRemoteId &&
          other.status == this.status &&
          other.progress == this.progress &&
          other.path == this.path &&
          other.errorMessage == this.errorMessage &&
          other.createdAt == this.createdAt &&
          other.finishedAt == this.finishedAt);
}

class DownloadsCompanion extends UpdateCompanion<DownloadRow> {
  final Value<int> id;
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<String> chapterSourceId;
  final Value<String> chapterRemoteId;
  final Value<String> status;
  final Value<double> progress;
  final Value<String?> path;
  final Value<String?> errorMessage;
  final Value<DateTime> createdAt;
  final Value<DateTime?> finishedAt;
  const DownloadsCompanion({
    this.id = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.chapterSourceId = const Value.absent(),
    this.chapterRemoteId = const Value.absent(),
    this.status = const Value.absent(),
    this.progress = const Value.absent(),
    this.path = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
  });
  DownloadsCompanion.insert({
    this.id = const Value.absent(),
    required String sourceId,
    required String remoteId,
    required String chapterSourceId,
    required String chapterRemoteId,
    required String status,
    this.progress = const Value.absent(),
    this.path = const Value.absent(),
    this.errorMessage = const Value.absent(),
    required DateTime createdAt,
    this.finishedAt = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       chapterSourceId = Value(chapterSourceId),
       chapterRemoteId = Value(chapterRemoteId),
       status = Value(status),
       createdAt = Value(createdAt);
  static Insertable<DownloadRow> custom({
    Expression<int>? id,
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<String>? chapterSourceId,
    Expression<String>? chapterRemoteId,
    Expression<String>? status,
    Expression<double>? progress,
    Expression<String>? path,
    Expression<String>? errorMessage,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? finishedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (chapterSourceId != null) 'chapter_source_id': chapterSourceId,
      if (chapterRemoteId != null) 'chapter_remote_id': chapterRemoteId,
      if (status != null) 'status': status,
      if (progress != null) 'progress': progress,
      if (path != null) 'path': path,
      if (errorMessage != null) 'error_message': errorMessage,
      if (createdAt != null) 'created_at': createdAt,
      if (finishedAt != null) 'finished_at': finishedAt,
    });
  }

  DownloadsCompanion copyWith({
    Value<int>? id,
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<String>? chapterSourceId,
    Value<String>? chapterRemoteId,
    Value<String>? status,
    Value<double>? progress,
    Value<String?>? path,
    Value<String?>? errorMessage,
    Value<DateTime>? createdAt,
    Value<DateTime?>? finishedAt,
  }) {
    return DownloadsCompanion(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      chapterSourceId: chapterSourceId ?? this.chapterSourceId,
      chapterRemoteId: chapterRemoteId ?? this.chapterRemoteId,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      path: path ?? this.path,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (chapterSourceId.present) {
      map['chapter_source_id'] = Variable<String>(chapterSourceId.value);
    }
    if (chapterRemoteId.present) {
      map['chapter_remote_id'] = Variable<String>(chapterRemoteId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (progress.present) {
      map['progress'] = Variable<double>(progress.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<DateTime>(finishedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadsCompanion(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('chapterSourceId: $chapterSourceId, ')
          ..write('chapterRemoteId: $chapterRemoteId, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('path: $path, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('createdAt: $createdAt, ')
          ..write('finishedAt: $finishedAt')
          ..write(')'))
        .toString();
  }
}

class $TrackBindsTable extends TrackBinds
    with TableInfo<$TrackBindsTable, TrackBindRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrackBindsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serviceMeta = const VerificationMeta(
    'service',
  );
  @override
  late final GeneratedColumn<String> service = GeneratedColumn<String>(
    'service',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteTrackIdMeta = const VerificationMeta(
    'remoteTrackId',
  );
  @override
  late final GeneratedColumn<String> remoteTrackId = GeneratedColumn<String>(
    'remote_track_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  @override
  late final GeneratedColumn<DateTime> syncedAt = GeneratedColumn<DateTime>(
    'synced_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sourceId,
    remoteId,
    service,
    remoteTrackId,
    syncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'track_binds';
  @override
  VerificationContext validateIntegrity(
    Insertable<TrackBindRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('service')) {
      context.handle(
        _serviceMeta,
        service.isAcceptableOrUnknown(data['service']!, _serviceMeta),
      );
    } else if (isInserting) {
      context.missing(_serviceMeta);
    }
    if (data.containsKey('remote_track_id')) {
      context.handle(
        _remoteTrackIdMeta,
        remoteTrackId.isAcceptableOrUnknown(
          data['remote_track_id']!,
          _remoteTrackIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_remoteTrackIdMeta);
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sourceId, remoteId, service};
  @override
  TrackBindRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackBindRow(
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      service: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}service'],
      )!,
      remoteTrackId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_track_id'],
      )!,
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}synced_at'],
      ),
    );
  }

  @override
  $TrackBindsTable createAlias(String alias) {
    return $TrackBindsTable(attachedDatabase, alias);
  }
}

class TrackBindRow extends DataClass implements Insertable<TrackBindRow> {
  final String sourceId;
  final String remoteId;

  /// bangumi / anilist / mal。
  final String service;

  /// 远端条目 ID。
  final String remoteTrackId;
  final DateTime? syncedAt;
  const TrackBindRow({
    required this.sourceId,
    required this.remoteId,
    required this.service,
    required this.remoteTrackId,
    this.syncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source_id'] = Variable<String>(sourceId);
    map['remote_id'] = Variable<String>(remoteId);
    map['service'] = Variable<String>(service);
    map['remote_track_id'] = Variable<String>(remoteTrackId);
    if (!nullToAbsent || syncedAt != null) {
      map['synced_at'] = Variable<DateTime>(syncedAt);
    }
    return map;
  }

  TrackBindsCompanion toCompanion(bool nullToAbsent) {
    return TrackBindsCompanion(
      sourceId: Value(sourceId),
      remoteId: Value(remoteId),
      service: Value(service),
      remoteTrackId: Value(remoteTrackId),
      syncedAt: syncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedAt),
    );
  }

  factory TrackBindRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackBindRow(
      sourceId: serializer.fromJson<String>(json['sourceId']),
      remoteId: serializer.fromJson<String>(json['remoteId']),
      service: serializer.fromJson<String>(json['service']),
      remoteTrackId: serializer.fromJson<String>(json['remoteTrackId']),
      syncedAt: serializer.fromJson<DateTime?>(json['syncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sourceId': serializer.toJson<String>(sourceId),
      'remoteId': serializer.toJson<String>(remoteId),
      'service': serializer.toJson<String>(service),
      'remoteTrackId': serializer.toJson<String>(remoteTrackId),
      'syncedAt': serializer.toJson<DateTime?>(syncedAt),
    };
  }

  TrackBindRow copyWith({
    String? sourceId,
    String? remoteId,
    String? service,
    String? remoteTrackId,
    Value<DateTime?> syncedAt = const Value.absent(),
  }) => TrackBindRow(
    sourceId: sourceId ?? this.sourceId,
    remoteId: remoteId ?? this.remoteId,
    service: service ?? this.service,
    remoteTrackId: remoteTrackId ?? this.remoteTrackId,
    syncedAt: syncedAt.present ? syncedAt.value : this.syncedAt,
  );
  TrackBindRow copyWithCompanion(TrackBindsCompanion data) {
    return TrackBindRow(
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      service: data.service.present ? data.service.value : this.service,
      remoteTrackId: data.remoteTrackId.present
          ? data.remoteTrackId.value
          : this.remoteTrackId,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackBindRow(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('service: $service, ')
          ..write('remoteTrackId: $remoteTrackId, ')
          ..write('syncedAt: $syncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(sourceId, remoteId, service, remoteTrackId, syncedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackBindRow &&
          other.sourceId == this.sourceId &&
          other.remoteId == this.remoteId &&
          other.service == this.service &&
          other.remoteTrackId == this.remoteTrackId &&
          other.syncedAt == this.syncedAt);
}

class TrackBindsCompanion extends UpdateCompanion<TrackBindRow> {
  final Value<String> sourceId;
  final Value<String> remoteId;
  final Value<String> service;
  final Value<String> remoteTrackId;
  final Value<DateTime?> syncedAt;
  final Value<int> rowid;
  const TrackBindsCompanion({
    this.sourceId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.service = const Value.absent(),
    this.remoteTrackId = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TrackBindsCompanion.insert({
    required String sourceId,
    required String remoteId,
    required String service,
    required String remoteTrackId,
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sourceId = Value(sourceId),
       remoteId = Value(remoteId),
       service = Value(service),
       remoteTrackId = Value(remoteTrackId);
  static Insertable<TrackBindRow> custom({
    Expression<String>? sourceId,
    Expression<String>? remoteId,
    Expression<String>? service,
    Expression<String>? remoteTrackId,
    Expression<DateTime>? syncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sourceId != null) 'source_id': sourceId,
      if (remoteId != null) 'remote_id': remoteId,
      if (service != null) 'service': service,
      if (remoteTrackId != null) 'remote_track_id': remoteTrackId,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TrackBindsCompanion copyWith({
    Value<String>? sourceId,
    Value<String>? remoteId,
    Value<String>? service,
    Value<String>? remoteTrackId,
    Value<DateTime?>? syncedAt,
    Value<int>? rowid,
  }) {
    return TrackBindsCompanion(
      sourceId: sourceId ?? this.sourceId,
      remoteId: remoteId ?? this.remoteId,
      service: service ?? this.service,
      remoteTrackId: remoteTrackId ?? this.remoteTrackId,
      syncedAt: syncedAt ?? this.syncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (service.present) {
      map['service'] = Variable<String>(service.value);
    }
    if (remoteTrackId.present) {
      map['remote_track_id'] = Variable<String>(remoteTrackId.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<DateTime>(syncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrackBindsCompanion(')
          ..write('sourceId: $sourceId, ')
          ..write('remoteId: $remoteId, ')
          ..write('service: $service, ')
          ..write('remoteTrackId: $remoteTrackId, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SourcesTable sources = $SourcesTable(this);
  late final $MediaItemsTable mediaItems = $MediaItemsTable(this);
  late final $ChaptersTable chapters = $ChaptersTable(this);
  late final $LibraryEntriesTable libraryEntries = $LibraryEntriesTable(this);
  late final $CategoriesTable categories = $CategoriesTable(this);
  late final $LibraryCategoryLinksTable libraryCategoryLinks =
      $LibraryCategoryLinksTable(this);
  late final $HistoriesTable histories = $HistoriesTable(this);
  late final $DownloadsTable downloads = $DownloadsTable(this);
  late final $TrackBindsTable trackBinds = $TrackBindsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sources,
    mediaItems,
    chapters,
    libraryEntries,
    categories,
    libraryCategoryLinks,
    histories,
    downloads,
    trackBinds,
  ];
}

typedef $$SourcesTableCreateCompanionBuilder = SourcesCompanion Function({
  required String id,
  required String name,
  required MediaType type,
  Value<String> lang,
  required SourceKind kind,
  Value<String?> version,
  Value<bool> enabled,
  Value<String?> ruleText,
  Value<String?> repoUrl,
  Value<DateTime?> updatedAt,
  Value<int> rowid,
});
typedef $$SourcesTableUpdateCompanionBuilder = SourcesCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<MediaType> type,
  Value<String> lang,
  Value<SourceKind> kind,
  Value<String?> version,
  Value<bool> enabled,
  Value<String?> ruleText,
  Value<String?> repoUrl,
  Value<DateTime?> updatedAt,
  Value<int> rowid,
});

class $$SourcesTableFilterComposer
    extends Composer<_$AppDatabase, $SourcesTable> {
  $$SourcesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<MediaType, MediaType, String> get type =>
      $composableBuilder(
        column: $table.type,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get lang => $composableBuilder(
    column: $table.lang,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<SourceKind, SourceKind, String> get kind =>
      $composableBuilder(
        column: $table.kind,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ruleText => $composableBuilder(
    column: $table.ruleText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get repoUrl => $composableBuilder(
    column: $table.repoUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SourcesTableOrderingComposer
    extends Composer<_$AppDatabase, $SourcesTable> {
  $$SourcesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lang => $composableBuilder(
    column: $table.lang,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ruleText => $composableBuilder(
    column: $table.ruleText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get repoUrl => $composableBuilder(
    column: $table.repoUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SourcesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SourcesTable> {
  $$SourcesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MediaType, String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get lang =>
      $composableBuilder(column: $table.lang, builder: (column) => column);

  GeneratedColumnWithTypeConverter<SourceKind, String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<String> get ruleText =>
      $composableBuilder(column: $table.ruleText, builder: (column) => column);

  GeneratedColumn<String> get repoUrl =>
      $composableBuilder(column: $table.repoUrl, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SourcesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SourcesTable,
          SourceRow,
          $$SourcesTableFilterComposer,
          $$SourcesTableOrderingComposer,
          $$SourcesTableAnnotationComposer,
          $$SourcesTableCreateCompanionBuilder,
          $$SourcesTableUpdateCompanionBuilder,
          (SourceRow, BaseReferences<_$AppDatabase, $SourcesTable, SourceRow>),
          SourceRow,
          PrefetchHooks Function()
        > {
  $$SourcesTableTableManager(_$AppDatabase db, $SourcesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SourcesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SourcesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SourcesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<MediaType> type = const Value.absent(),
                Value<String> lang = const Value.absent(),
                Value<SourceKind> kind = const Value.absent(),
                Value<String?> version = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<String?> ruleText = const Value.absent(),
                Value<String?> repoUrl = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourcesCompanion(
                id: id,
                name: name,
                type: type,
                lang: lang,
                kind: kind,
                version: version,
                enabled: enabled,
                ruleText: ruleText,
                repoUrl: repoUrl,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required MediaType type,
                Value<String> lang = const Value.absent(),
                required SourceKind kind,
                Value<String?> version = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<String?> ruleText = const Value.absent(),
                Value<String?> repoUrl = const Value.absent(),
                Value<DateTime?> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SourcesCompanion.insert(
                id: id,
                name: name,
                type: type,
                lang: lang,
                kind: kind,
                version: version,
                enabled: enabled,
                ruleText: ruleText,
                repoUrl: repoUrl,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SourcesTable, SourceRow>(table),
                  BaseReferences<_$AppDatabase, $SourcesTable, SourceRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SourcesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SourcesTable,
      SourceRow,
      $$SourcesTableFilterComposer,
      $$SourcesTableOrderingComposer,
      $$SourcesTableAnnotationComposer,
      $$SourcesTableCreateCompanionBuilder,
      $$SourcesTableUpdateCompanionBuilder,
      (SourceRow, BaseReferences<_$AppDatabase, $SourcesTable, SourceRow>),
      SourceRow,
      PrefetchHooks Function()
    >;
typedef $$MediaItemsTableCreateCompanionBuilder = MediaItemsCompanion Function({
  required String sourceId,
  required String remoteId,
  required MediaType type,
  required String title,
  Value<String?> coverUrl,
  Value<String?> author,
  Value<String?> description,
  Value<String?> tagsJson,
  Value<double?> rating,
  Value<String?> status,
  Value<String?> detailJson,
  Value<DateTime?> cachedAt,
  Value<int> rowid,
});
typedef $$MediaItemsTableUpdateCompanionBuilder = MediaItemsCompanion Function({
  Value<String> sourceId,
  Value<String> remoteId,
  Value<MediaType> type,
  Value<String> title,
  Value<String?> coverUrl,
  Value<String?> author,
  Value<String?> description,
  Value<String?> tagsJson,
  Value<double?> rating,
  Value<String?> status,
  Value<String?> detailJson,
  Value<DateTime?> cachedAt,
  Value<int> rowid,
});

class $$MediaItemsTableFilterComposer
    extends Composer<_$AppDatabase, $MediaItemsTable> {
  $$MediaItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<MediaType, MediaType, String> get type =>
      $composableBuilder(
        column: $table.type,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get detailJson => $composableBuilder(
    column: $table.detailJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MediaItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $MediaItemsTable> {
  $$MediaItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get detailJson => $composableBuilder(
    column: $table.detailJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MediaItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MediaItemsTable> {
  $$MediaItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MediaType, String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<double> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get detailJson => $composableBuilder(
    column: $table.detailJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);
}

class $$MediaItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MediaItemsTable,
          MediaItemRow,
          $$MediaItemsTableFilterComposer,
          $$MediaItemsTableOrderingComposer,
          $$MediaItemsTableAnnotationComposer,
          $$MediaItemsTableCreateCompanionBuilder,
          $$MediaItemsTableUpdateCompanionBuilder,
          (
            MediaItemRow,
            BaseReferences<_$AppDatabase, $MediaItemsTable, MediaItemRow>,
          ),
          MediaItemRow,
          PrefetchHooks Function()
        > {
  $$MediaItemsTableTableManager(_$AppDatabase db, $MediaItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<MediaType> type = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> coverUrl = const Value.absent(),
                Value<String?> author = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<String?> tagsJson = const Value.absent(),
                Value<double?> rating = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<String?> detailJson = const Value.absent(),
                Value<DateTime?> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaItemsCompanion(
                sourceId: sourceId,
                remoteId: remoteId,
                type: type,
                title: title,
                coverUrl: coverUrl,
                author: author,
                description: description,
                tagsJson: tagsJson,
                rating: rating,
                status: status,
                detailJson: detailJson,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceId,
                required String remoteId,
                required MediaType type,
                required String title,
                Value<String?> coverUrl = const Value.absent(),
                Value<String?> author = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<String?> tagsJson = const Value.absent(),
                Value<double?> rating = const Value.absent(),
                Value<String?> status = const Value.absent(),
                Value<String?> detailJson = const Value.absent(),
                Value<DateTime?> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaItemsCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                type: type,
                title: title,
                coverUrl: coverUrl,
                author: author,
                description: description,
                tagsJson: tagsJson,
                rating: rating,
                status: status,
                detailJson: detailJson,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MediaItemsTable, MediaItemRow>(table),
                  BaseReferences<_$AppDatabase, $MediaItemsTable, MediaItemRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MediaItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MediaItemsTable,
      MediaItemRow,
      $$MediaItemsTableFilterComposer,
      $$MediaItemsTableOrderingComposer,
      $$MediaItemsTableAnnotationComposer,
      $$MediaItemsTableCreateCompanionBuilder,
      $$MediaItemsTableUpdateCompanionBuilder,
      (
        MediaItemRow,
        BaseReferences<_$AppDatabase, $MediaItemsTable, MediaItemRow>,
      ),
      MediaItemRow,
      PrefetchHooks Function()
    >;
typedef $$ChaptersTableCreateCompanionBuilder = ChaptersCompanion Function({
  required String sourceId,
  required String remoteId,
  required String itemSourceId,
  required String itemRemoteId,
  required String title,
  Value<double?> number,
  Value<int> sortIndex,
  Value<String?> volumeTitle,
  Value<DateTime?> releaseDate,
  Value<bool> locked,
  Value<String?> contentJson,
  Value<int> rowid,
});
typedef $$ChaptersTableUpdateCompanionBuilder = ChaptersCompanion Function({
  Value<String> sourceId,
  Value<String> remoteId,
  Value<String> itemSourceId,
  Value<String> itemRemoteId,
  Value<String> title,
  Value<double?> number,
  Value<int> sortIndex,
  Value<String?> volumeTitle,
  Value<DateTime?> releaseDate,
  Value<bool> locked,
  Value<String?> contentJson,
  Value<int> rowid,
});

class $$ChaptersTableFilterComposer
    extends Composer<_$AppDatabase, $ChaptersTable> {
  $$ChaptersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemSourceId => $composableBuilder(
    column: $table.itemSourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemRemoteId => $composableBuilder(
    column: $table.itemRemoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get number => $composableBuilder(
    column: $table.number,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get volumeTitle => $composableBuilder(
    column: $table.volumeTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get releaseDate => $composableBuilder(
    column: $table.releaseDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChaptersTableOrderingComposer
    extends Composer<_$AppDatabase, $ChaptersTable> {
  $$ChaptersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemSourceId => $composableBuilder(
    column: $table.itemSourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemRemoteId => $composableBuilder(
    column: $table.itemRemoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get number => $composableBuilder(
    column: $table.number,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get volumeTitle => $composableBuilder(
    column: $table.volumeTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get releaseDate => $composableBuilder(
    column: $table.releaseDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChaptersTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChaptersTable> {
  $$ChaptersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get itemSourceId => $composableBuilder(
    column: $table.itemSourceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get itemRemoteId => $composableBuilder(
    column: $table.itemRemoteId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<double> get number =>
      $composableBuilder(column: $table.number, builder: (column) => column);

  GeneratedColumn<int> get sortIndex =>
      $composableBuilder(column: $table.sortIndex, builder: (column) => column);

  GeneratedColumn<String> get volumeTitle => $composableBuilder(
    column: $table.volumeTitle,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get releaseDate => $composableBuilder(
    column: $table.releaseDate,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get locked =>
      $composableBuilder(column: $table.locked, builder: (column) => column);

  GeneratedColumn<String> get contentJson => $composableBuilder(
    column: $table.contentJson,
    builder: (column) => column,
  );
}

class $$ChaptersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChaptersTable,
          ChapterRow,
          $$ChaptersTableFilterComposer,
          $$ChaptersTableOrderingComposer,
          $$ChaptersTableAnnotationComposer,
          $$ChaptersTableCreateCompanionBuilder,
          $$ChaptersTableUpdateCompanionBuilder,
          (
            ChapterRow,
            BaseReferences<_$AppDatabase, $ChaptersTable, ChapterRow>,
          ),
          ChapterRow,
          PrefetchHooks Function()
        > {
  $$ChaptersTableTableManager(_$AppDatabase db, $ChaptersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChaptersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChaptersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChaptersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<String> itemSourceId = const Value.absent(),
                Value<String> itemRemoteId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<double?> number = const Value.absent(),
                Value<int> sortIndex = const Value.absent(),
                Value<String?> volumeTitle = const Value.absent(),
                Value<DateTime?> releaseDate = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                Value<String?> contentJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChaptersCompanion(
                sourceId: sourceId,
                remoteId: remoteId,
                itemSourceId: itemSourceId,
                itemRemoteId: itemRemoteId,
                title: title,
                number: number,
                sortIndex: sortIndex,
                volumeTitle: volumeTitle,
                releaseDate: releaseDate,
                locked: locked,
                contentJson: contentJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceId,
                required String remoteId,
                required String itemSourceId,
                required String itemRemoteId,
                required String title,
                Value<double?> number = const Value.absent(),
                Value<int> sortIndex = const Value.absent(),
                Value<String?> volumeTitle = const Value.absent(),
                Value<DateTime?> releaseDate = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                Value<String?> contentJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChaptersCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                itemSourceId: itemSourceId,
                itemRemoteId: itemRemoteId,
                title: title,
                number: number,
                sortIndex: sortIndex,
                volumeTitle: volumeTitle,
                releaseDate: releaseDate,
                locked: locked,
                contentJson: contentJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChaptersTable, ChapterRow>(table),
                  BaseReferences<_$AppDatabase, $ChaptersTable, ChapterRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChaptersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChaptersTable,
      ChapterRow,
      $$ChaptersTableFilterComposer,
      $$ChaptersTableOrderingComposer,
      $$ChaptersTableAnnotationComposer,
      $$ChaptersTableCreateCompanionBuilder,
      $$ChaptersTableUpdateCompanionBuilder,
      (ChapterRow, BaseReferences<_$AppDatabase, $ChaptersTable, ChapterRow>),
      ChapterRow,
      PrefetchHooks Function()
    >;
typedef $$LibraryEntriesTableCreateCompanionBuilder =
    LibraryEntriesCompanion Function({
      required String sourceId,
      required String remoteId,
      required MediaType type,
      Value<double> progress,
      Value<int?> score,
      Value<String> status,
      Value<bool> pinned,
      Value<int> unreadCount,
      required DateTime addedAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$LibraryEntriesTableUpdateCompanionBuilder =
    LibraryEntriesCompanion Function({
      Value<String> sourceId,
      Value<String> remoteId,
      Value<MediaType> type,
      Value<double> progress,
      Value<int?> score,
      Value<String> status,
      Value<bool> pinned,
      Value<int> unreadCount,
      Value<DateTime> addedAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$LibraryEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryEntriesTable> {
  $$LibraryEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<MediaType, MediaType, String> get type =>
      $composableBuilder(
        column: $table.type,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LibraryEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryEntriesTable> {
  $$LibraryEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryEntriesTable> {
  $$LibraryEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MediaType, String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<double> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<int> get score =>
      $composableBuilder(column: $table.score, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);

  GeneratedColumn<int> get unreadCount => $composableBuilder(
    column: $table.unreadCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LibraryEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryEntriesTable,
          LibraryEntryRow,
          $$LibraryEntriesTableFilterComposer,
          $$LibraryEntriesTableOrderingComposer,
          $$LibraryEntriesTableAnnotationComposer,
          $$LibraryEntriesTableCreateCompanionBuilder,
          $$LibraryEntriesTableUpdateCompanionBuilder,
          (
            LibraryEntryRow,
            BaseReferences<
              _$AppDatabase,
              $LibraryEntriesTable,
              LibraryEntryRow
            >,
          ),
          LibraryEntryRow,
          PrefetchHooks Function()
        > {
  $$LibraryEntriesTableTableManager(
    _$AppDatabase db,
    $LibraryEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<MediaType> type = const Value.absent(),
                Value<double> progress = const Value.absent(),
                Value<int?> score = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> unreadCount = const Value.absent(),
                Value<DateTime> addedAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryEntriesCompanion(
                sourceId: sourceId,
                remoteId: remoteId,
                type: type,
                progress: progress,
                score: score,
                status: status,
                pinned: pinned,
                unreadCount: unreadCount,
                addedAt: addedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceId,
                required String remoteId,
                required MediaType type,
                Value<double> progress = const Value.absent(),
                Value<int?> score = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> unreadCount = const Value.absent(),
                required DateTime addedAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LibraryEntriesCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                type: type,
                progress: progress,
                score: score,
                status: status,
                pinned: pinned,
                unreadCount: unreadCount,
                addedAt: addedAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LibraryEntriesTable, LibraryEntryRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LibraryEntriesTable,
                    LibraryEntryRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibraryEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryEntriesTable,
      LibraryEntryRow,
      $$LibraryEntriesTableFilterComposer,
      $$LibraryEntriesTableOrderingComposer,
      $$LibraryEntriesTableAnnotationComposer,
      $$LibraryEntriesTableCreateCompanionBuilder,
      $$LibraryEntriesTableUpdateCompanionBuilder,
      (
        LibraryEntryRow,
        BaseReferences<_$AppDatabase, $LibraryEntriesTable, LibraryEntryRow>,
      ),
      LibraryEntryRow,
      PrefetchHooks Function()
    >;
typedef $$CategoriesTableCreateCompanionBuilder = CategoriesCompanion Function({
  Value<int> id,
  required String name,
  Value<int> sortIndex,
});
typedef $$CategoriesTableUpdateCompanionBuilder = CategoriesCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<int> sortIndex,
});

class $$CategoriesTableFilterComposer
    extends Composer<_$AppDatabase, $CategoriesTable> {
  $$CategoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CategoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $CategoriesTable> {
  $$CategoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortIndex => $composableBuilder(
    column: $table.sortIndex,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CategoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CategoriesTable> {
  $$CategoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sortIndex =>
      $composableBuilder(column: $table.sortIndex, builder: (column) => column);
}

class $$CategoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CategoriesTable,
          CategoryRow,
          $$CategoriesTableFilterComposer,
          $$CategoriesTableOrderingComposer,
          $$CategoriesTableAnnotationComposer,
          $$CategoriesTableCreateCompanionBuilder,
          $$CategoriesTableUpdateCompanionBuilder,
          (
            CategoryRow,
            BaseReferences<_$AppDatabase, $CategoriesTable, CategoryRow>,
          ),
          CategoryRow,
          PrefetchHooks Function()
        > {
  $$CategoriesTableTableManager(_$AppDatabase db, $CategoriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CategoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CategoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CategoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> sortIndex = const Value.absent(),
          }) => CategoriesCompanion(id: id, name: name, sortIndex: sortIndex),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<int> sortIndex = const Value.absent(),
              }) => CategoriesCompanion.insert(
                id: id,
                name: name,
                sortIndex: sortIndex,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CategoriesTable, CategoryRow>(table),
                  BaseReferences<_$AppDatabase, $CategoriesTable, CategoryRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CategoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CategoriesTable,
      CategoryRow,
      $$CategoriesTableFilterComposer,
      $$CategoriesTableOrderingComposer,
      $$CategoriesTableAnnotationComposer,
      $$CategoriesTableCreateCompanionBuilder,
      $$CategoriesTableUpdateCompanionBuilder,
      (
        CategoryRow,
        BaseReferences<_$AppDatabase, $CategoriesTable, CategoryRow>,
      ),
      CategoryRow,
      PrefetchHooks Function()
    >;
typedef $$LibraryCategoryLinksTableCreateCompanionBuilder =
    LibraryCategoryLinksCompanion Function({
      required String sourceId,
      required String remoteId,
      required int categoryId,
      Value<int> rowid,
    });
typedef $$LibraryCategoryLinksTableUpdateCompanionBuilder =
    LibraryCategoryLinksCompanion Function({
      Value<String> sourceId,
      Value<String> remoteId,
      Value<int> categoryId,
      Value<int> rowid,
    });

class $$LibraryCategoryLinksTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryCategoryLinksTable> {
  $$LibraryCategoryLinksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get categoryId => $composableBuilder(
    column: $table.categoryId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LibraryCategoryLinksTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryCategoryLinksTable> {
  $$LibraryCategoryLinksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get categoryId => $composableBuilder(
    column: $table.categoryId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryCategoryLinksTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryCategoryLinksTable> {
  $$LibraryCategoryLinksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<int> get categoryId => $composableBuilder(
    column: $table.categoryId,
    builder: (column) => column,
  );
}

class $$LibraryCategoryLinksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryCategoryLinksTable,
          LibraryCategoryLinkRow,
          $$LibraryCategoryLinksTableFilterComposer,
          $$LibraryCategoryLinksTableOrderingComposer,
          $$LibraryCategoryLinksTableAnnotationComposer,
          $$LibraryCategoryLinksTableCreateCompanionBuilder,
          $$LibraryCategoryLinksTableUpdateCompanionBuilder,
          (
            LibraryCategoryLinkRow,
            BaseReferences<
              _$AppDatabase,
              $LibraryCategoryLinksTable,
              LibraryCategoryLinkRow
            >,
          ),
          LibraryCategoryLinkRow,
          PrefetchHooks Function()
        > {
  $$LibraryCategoryLinksTableTableManager(
    _$AppDatabase db,
    $LibraryCategoryLinksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryCategoryLinksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryCategoryLinksTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LibraryCategoryLinksTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<int> categoryId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryCategoryLinksCompanion(
                sourceId: sourceId,
                remoteId: remoteId,
                categoryId: categoryId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceId,
                required String remoteId,
                required int categoryId,
                Value<int> rowid = const Value.absent(),
              }) => LibraryCategoryLinksCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                categoryId: categoryId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $LibraryCategoryLinksTable,
                    LibraryCategoryLinkRow
                  >(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LibraryCategoryLinksTable,
                    LibraryCategoryLinkRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibraryCategoryLinksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryCategoryLinksTable,
      LibraryCategoryLinkRow,
      $$LibraryCategoryLinksTableFilterComposer,
      $$LibraryCategoryLinksTableOrderingComposer,
      $$LibraryCategoryLinksTableAnnotationComposer,
      $$LibraryCategoryLinksTableCreateCompanionBuilder,
      $$LibraryCategoryLinksTableUpdateCompanionBuilder,
      (
        LibraryCategoryLinkRow,
        BaseReferences<
          _$AppDatabase,
          $LibraryCategoryLinksTable,
          LibraryCategoryLinkRow
        >,
      ),
      LibraryCategoryLinkRow,
      PrefetchHooks Function()
    >;
typedef $$HistoriesTableCreateCompanionBuilder = HistoriesCompanion Function({
  Value<int> id,
  required String sourceId,
  required String remoteId,
  required String chapterSourceId,
  required String chapterRemoteId,
  Value<double> position,
  Value<String?> device,
  required DateTime visitedAt,
  Value<bool> incognito,
});
typedef $$HistoriesTableUpdateCompanionBuilder = HistoriesCompanion Function({
  Value<int> id,
  Value<String> sourceId,
  Value<String> remoteId,
  Value<String> chapterSourceId,
  Value<String> chapterRemoteId,
  Value<double> position,
  Value<String?> device,
  Value<DateTime> visitedAt,
  Value<bool> incognito,
});

class $$HistoriesTableFilterComposer
    extends Composer<_$AppDatabase, $HistoriesTable> {
  $$HistoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chapterSourceId => $composableBuilder(
    column: $table.chapterSourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chapterRemoteId => $composableBuilder(
    column: $table.chapterRemoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get device => $composableBuilder(
    column: $table.device,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get incognito => $composableBuilder(
    column: $table.incognito,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HistoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoriesTable> {
  $$HistoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chapterSourceId => $composableBuilder(
    column: $table.chapterSourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chapterRemoteId => $composableBuilder(
    column: $table.chapterRemoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get device => $composableBuilder(
    column: $table.device,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get incognito => $composableBuilder(
    column: $table.incognito,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HistoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoriesTable> {
  $$HistoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get chapterSourceId => $composableBuilder(
    column: $table.chapterSourceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get chapterRemoteId => $composableBuilder(
    column: $table.chapterRemoteId,
    builder: (column) => column,
  );

  GeneratedColumn<double> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get device =>
      $composableBuilder(column: $table.device, builder: (column) => column);

  GeneratedColumn<DateTime> get visitedAt =>
      $composableBuilder(column: $table.visitedAt, builder: (column) => column);

  GeneratedColumn<bool> get incognito =>
      $composableBuilder(column: $table.incognito, builder: (column) => column);
}

class $$HistoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HistoriesTable,
          HistoryRow,
          $$HistoriesTableFilterComposer,
          $$HistoriesTableOrderingComposer,
          $$HistoriesTableAnnotationComposer,
          $$HistoriesTableCreateCompanionBuilder,
          $$HistoriesTableUpdateCompanionBuilder,
          (
            HistoryRow,
            BaseReferences<_$AppDatabase, $HistoriesTable, HistoryRow>,
          ),
          HistoryRow,
          PrefetchHooks Function()
        > {
  $$HistoriesTableTableManager(_$AppDatabase db, $HistoriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<String> chapterSourceId = const Value.absent(),
                Value<String> chapterRemoteId = const Value.absent(),
                Value<double> position = const Value.absent(),
                Value<String?> device = const Value.absent(),
                Value<DateTime> visitedAt = const Value.absent(),
                Value<bool> incognito = const Value.absent(),
              }) => HistoriesCompanion(
                id: id,
                sourceId: sourceId,
                remoteId: remoteId,
                chapterSourceId: chapterSourceId,
                chapterRemoteId: chapterRemoteId,
                position: position,
                device: device,
                visitedAt: visitedAt,
                incognito: incognito,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String sourceId,
                required String remoteId,
                required String chapterSourceId,
                required String chapterRemoteId,
                Value<double> position = const Value.absent(),
                Value<String?> device = const Value.absent(),
                required DateTime visitedAt,
                Value<bool> incognito = const Value.absent(),
              }) => HistoriesCompanion.insert(
                id: id,
                sourceId: sourceId,
                remoteId: remoteId,
                chapterSourceId: chapterSourceId,
                chapterRemoteId: chapterRemoteId,
                position: position,
                device: device,
                visitedAt: visitedAt,
                incognito: incognito,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HistoriesTable, HistoryRow>(table),
                  BaseReferences<_$AppDatabase, $HistoriesTable, HistoryRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HistoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HistoriesTable,
      HistoryRow,
      $$HistoriesTableFilterComposer,
      $$HistoriesTableOrderingComposer,
      $$HistoriesTableAnnotationComposer,
      $$HistoriesTableCreateCompanionBuilder,
      $$HistoriesTableUpdateCompanionBuilder,
      (HistoryRow, BaseReferences<_$AppDatabase, $HistoriesTable, HistoryRow>),
      HistoryRow,
      PrefetchHooks Function()
    >;
typedef $$DownloadsTableCreateCompanionBuilder = DownloadsCompanion Function({
  Value<int> id,
  required String sourceId,
  required String remoteId,
  required String chapterSourceId,
  required String chapterRemoteId,
  required String status,
  Value<double> progress,
  Value<String?> path,
  Value<String?> errorMessage,
  required DateTime createdAt,
  Value<DateTime?> finishedAt,
});
typedef $$DownloadsTableUpdateCompanionBuilder = DownloadsCompanion Function({
  Value<int> id,
  Value<String> sourceId,
  Value<String> remoteId,
  Value<String> chapterSourceId,
  Value<String> chapterRemoteId,
  Value<String> status,
  Value<double> progress,
  Value<String?> path,
  Value<String?> errorMessage,
  Value<DateTime> createdAt,
  Value<DateTime?> finishedAt,
});

class $$DownloadsTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadsTable> {
  $$DownloadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chapterSourceId => $composableBuilder(
    column: $table.chapterSourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get chapterRemoteId => $composableBuilder(
    column: $table.chapterRemoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadsTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadsTable> {
  $$DownloadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chapterSourceId => $composableBuilder(
    column: $table.chapterSourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chapterRemoteId => $composableBuilder(
    column: $table.chapterRemoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadsTable> {
  $$DownloadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get chapterSourceId => $composableBuilder(
    column: $table.chapterSourceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get chapterRemoteId => $composableBuilder(
    column: $table.chapterRemoteId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<double> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );
}

class $$DownloadsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadsTable,
          DownloadRow,
          $$DownloadsTableFilterComposer,
          $$DownloadsTableOrderingComposer,
          $$DownloadsTableAnnotationComposer,
          $$DownloadsTableCreateCompanionBuilder,
          $$DownloadsTableUpdateCompanionBuilder,
          (
            DownloadRow,
            BaseReferences<_$AppDatabase, $DownloadsTable, DownloadRow>,
          ),
          DownloadRow,
          PrefetchHooks Function()
        > {
  $$DownloadsTableTableManager(_$AppDatabase db, $DownloadsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<String> chapterSourceId = const Value.absent(),
                Value<String> chapterRemoteId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<double> progress = const Value.absent(),
                Value<String?> path = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> finishedAt = const Value.absent(),
              }) => DownloadsCompanion(
                id: id,
                sourceId: sourceId,
                remoteId: remoteId,
                chapterSourceId: chapterSourceId,
                chapterRemoteId: chapterRemoteId,
                status: status,
                progress: progress,
                path: path,
                errorMessage: errorMessage,
                createdAt: createdAt,
                finishedAt: finishedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String sourceId,
                required String remoteId,
                required String chapterSourceId,
                required String chapterRemoteId,
                required String status,
                Value<double> progress = const Value.absent(),
                Value<String?> path = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                required DateTime createdAt,
                Value<DateTime?> finishedAt = const Value.absent(),
              }) => DownloadsCompanion.insert(
                id: id,
                sourceId: sourceId,
                remoteId: remoteId,
                chapterSourceId: chapterSourceId,
                chapterRemoteId: chapterRemoteId,
                status: status,
                progress: progress,
                path: path,
                errorMessage: errorMessage,
                createdAt: createdAt,
                finishedAt: finishedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DownloadsTable, DownloadRow>(table),
                  BaseReferences<_$AppDatabase, $DownloadsTable, DownloadRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadsTable,
      DownloadRow,
      $$DownloadsTableFilterComposer,
      $$DownloadsTableOrderingComposer,
      $$DownloadsTableAnnotationComposer,
      $$DownloadsTableCreateCompanionBuilder,
      $$DownloadsTableUpdateCompanionBuilder,
      (
        DownloadRow,
        BaseReferences<_$AppDatabase, $DownloadsTable, DownloadRow>,
      ),
      DownloadRow,
      PrefetchHooks Function()
    >;
typedef $$TrackBindsTableCreateCompanionBuilder = TrackBindsCompanion Function({
  required String sourceId,
  required String remoteId,
  required String service,
  required String remoteTrackId,
  Value<DateTime?> syncedAt,
  Value<int> rowid,
});
typedef $$TrackBindsTableUpdateCompanionBuilder = TrackBindsCompanion Function({
  Value<String> sourceId,
  Value<String> remoteId,
  Value<String> service,
  Value<String> remoteTrackId,
  Value<DateTime?> syncedAt,
  Value<int> rowid,
});

class $$TrackBindsTableFilterComposer
    extends Composer<_$AppDatabase, $TrackBindsTable> {
  $$TrackBindsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get service => $composableBuilder(
    column: $table.service,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteTrackId => $composableBuilder(
    column: $table.remoteTrackId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TrackBindsTableOrderingComposer
    extends Composer<_$AppDatabase, $TrackBindsTable> {
  $$TrackBindsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get service => $composableBuilder(
    column: $table.service,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteTrackId => $composableBuilder(
    column: $table.remoteTrackId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TrackBindsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TrackBindsTable> {
  $$TrackBindsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<String> get service =>
      $composableBuilder(column: $table.service, builder: (column) => column);

  GeneratedColumn<String> get remoteTrackId => $composableBuilder(
    column: $table.remoteTrackId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);
}

class $$TrackBindsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TrackBindsTable,
          TrackBindRow,
          $$TrackBindsTableFilterComposer,
          $$TrackBindsTableOrderingComposer,
          $$TrackBindsTableAnnotationComposer,
          $$TrackBindsTableCreateCompanionBuilder,
          $$TrackBindsTableUpdateCompanionBuilder,
          (
            TrackBindRow,
            BaseReferences<_$AppDatabase, $TrackBindsTable, TrackBindRow>,
          ),
          TrackBindRow,
          PrefetchHooks Function()
        > {
  $$TrackBindsTableTableManager(_$AppDatabase db, $TrackBindsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrackBindsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrackBindsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrackBindsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sourceId = const Value.absent(),
                Value<String> remoteId = const Value.absent(),
                Value<String> service = const Value.absent(),
                Value<String> remoteTrackId = const Value.absent(),
                Value<DateTime?> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrackBindsCompanion(
                sourceId: sourceId,
                remoteId: remoteId,
                service: service,
                remoteTrackId: remoteTrackId,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sourceId,
                required String remoteId,
                required String service,
                required String remoteTrackId,
                Value<DateTime?> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrackBindsCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                service: service,
                remoteTrackId: remoteTrackId,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TrackBindsTable, TrackBindRow>(table),
                  BaseReferences<_$AppDatabase, $TrackBindsTable, TrackBindRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TrackBindsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TrackBindsTable,
      TrackBindRow,
      $$TrackBindsTableFilterComposer,
      $$TrackBindsTableOrderingComposer,
      $$TrackBindsTableAnnotationComposer,
      $$TrackBindsTableCreateCompanionBuilder,
      $$TrackBindsTableUpdateCompanionBuilder,
      (
        TrackBindRow,
        BaseReferences<_$AppDatabase, $TrackBindsTable, TrackBindRow>,
      ),
      TrackBindRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SourcesTableTableManager get sources =>
      $$SourcesTableTableManager(_db, _db.sources);
  $$MediaItemsTableTableManager get mediaItems =>
      $$MediaItemsTableTableManager(_db, _db.mediaItems);
  $$ChaptersTableTableManager get chapters =>
      $$ChaptersTableTableManager(_db, _db.chapters);
  $$LibraryEntriesTableTableManager get libraryEntries =>
      $$LibraryEntriesTableTableManager(_db, _db.libraryEntries);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db, _db.categories);
  $$LibraryCategoryLinksTableTableManager get libraryCategoryLinks =>
      $$LibraryCategoryLinksTableTableManager(_db, _db.libraryCategoryLinks);
  $$HistoriesTableTableManager get histories =>
      $$HistoriesTableTableManager(_db, _db.histories);
  $$DownloadsTableTableManager get downloads =>
      $$DownloadsTableTableManager(_db, _db.downloads);
  $$TrackBindsTableTableManager get trackBinds =>
      $$TrackBindsTableTableManager(_db, _db.trackBinds);
}
