// A FactorClassifier built from constructed FactorInfo values carrying the real factor_info tags,
// plus builders for synthetic self-factor lists over it. No module file is read.
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';

FactorInfo _info(int sid, String tag) =>
    FactorInfo(sid: sid, sortKey: sid, names: ['$sid'], descriptions: const [''], tags: {tag});

/// Coloured: 11/12 blue (`factor_status`), 21 red (`factor_aptitude`), 31/32 green
/// (`factor_unique_skill`). White: 1001-1099 `factor_normal_skill`, 2001-2009 `factor_status_gene`,
/// 3001 `factor_aptitude_gene`.
final testClassifier = FactorClassifier.fromInfo([
  _info(11, 'factor_status'),
  _info(12, 'factor_status'),
  _info(21, 'factor_aptitude'),
  _info(31, 'factor_unique_skill'),
  _info(32, 'factor_unique_skill'),
  for (var sid = 1001; sid < 1100; sid++) _info(sid, 'factor_normal_skill'),
  for (var sid = 2001; sid < 2010; sid++) _info(sid, 'factor_status_gene'),
  _info(3001, 'factor_aptitude_gene'),
]);

/// [count] white factors from id [from] on, with stars cycling 1, 2, 3.
List<Factor> whites(int count, {int from = 1001}) => [for (var i = 0; i < count; i++) Factor(from + i, i % 3 + 1)];

/// One blue (11), one red (21) and one green ([greenId]) factor with the given stars.
List<Factor> coloured(int blue, int red, int green, {int greenId = 31}) => [
  Factor(11, blue),
  Factor(21, red),
  Factor(greenId, green),
];
