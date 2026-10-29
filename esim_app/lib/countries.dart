import 'package:flutter/material.dart';

/// Country / region metadata (Onlylink style: small flag + Chinese name).
class Country {
  final String code; // matches plan.country_code
  final String nameZh;
  final String nameEn;
  const Country(this.code, this.nameZh, this.nameEn);

  /// ISO-3166 alpha-2 for flag rendering (regions map to a representative flag).
  String get iso2 => const {'GLOBAL': 'UN', 'ASIA': 'UN', 'EU': 'EU'}[code] ?? code;
}

const Map<String, Country> kCountries = {
  'GLOBAL': Country('GLOBAL', '全球', 'Global'),
  'ASIA': Country('ASIA', '亚洲', 'Asia'),
  'VN': Country('VN', '越南', 'Vietnam'),
  'JP': Country('JP', '日本', 'Japan'),
  'US': Country('US', '美国', 'United States'),
  'TH': Country('TH', '泰国', 'Thailand'),
  'KR': Country('KR', '韩国', 'South Korea'),
  'SG': Country('SG', '新加坡', 'Singapore'),
  'EU': Country('EU', '欧洲', 'Europe'),
  'HK': Country('HK', '中国香港', 'Hong Kong'),
};

Country countryOf(String code) => kCountries[code] ?? Country(code, code, code);

const kFeaturedOrder = ['GLOBAL', 'ASIA', 'VN', 'JP', 'US', 'TH', 'KR', 'SG', 'EU', 'HK'];

/// A representative destination photo per country (used in plan cards / categories).
String destinationPhoto(String code, {String cover = ""}) {
  // Prefer an admin-uploaded cover image when provided.
  if (cover.isNotEmpty) return cover;
  const map = {
    'VN': 'https://images.unsplash.com/photo-1528127269322-539801943592?w=400&q=70',
    'JP': 'https://images.unsplash.com/photo-1493976040374-85c8e12f0c0e?w=400&q=70',
    'US': 'https://images.unsplash.com/photo-1485738422979-f5c462d49f74?w=400&q=70',
    'TH': 'https://images.unsplash.com/photo-1552465011-b4e21bf6e79a?w=400&q=70',
    'KR': 'https://images.unsplash.com/photo-1517154421773-0529f29ea451?w=400&q=70',
    'SG': 'https://images.unsplash.com/photo-1525625293386-3f8f99389edd?w=400&q=70',
    'GLOBAL': 'https://images.unsplash.com/photo-1451187580459-43490279c0fa?w=400&q=70',
    'ASIA': 'https://images.unsplash.com/photo-1508009603885-50cf7c579365?w=400&q=70',
    'EU': 'https://images.unsplash.com/photo-1467269204594-9661b134dd2b?w=400&q=70',
    'HK': 'https://images.unsplash.com/photo-1536599018102-9f803c140fc1?w=400&q=70',
  };
  return map[code] ?? 'https://images.unsplash.com/photo-1451187580459-43490279c0fa?w=400&q=70';
}

/// Renders a country flag via flagcdn (works everywhere, unlike emoji on Windows).
class FlagImage extends StatelessWidget {
  final String iso2;
  final double width;
  final double radius;
  const FlagImage(this.iso2, {super.key, this.width = 36, this.radius = 5});

  @override
  Widget build(BuildContext context) {
    if (iso2 == 'UN' || iso2 == 'EU' || iso2.length != 2) {
      return Icon(iso2 == 'EU' ? Icons.euro : Icons.public, color: Colors.white, size: width * 0.6);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        'https://flagcdn.com/w80/${iso2.toLowerCase()}.png',
        width: width,
        height: width * 0.7,
        fit: BoxFit.cover,
        errorBuilder: (_, e, s) => Icon(Icons.flag, color: Colors.white, size: width * 0.6),
      ),
    );
  }
}
