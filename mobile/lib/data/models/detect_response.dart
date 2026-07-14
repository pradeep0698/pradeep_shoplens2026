class DetectedItemDto {
  final String name;
  final List<int>? box; // [y_min, x_min, y_max, x_max] on a 0-1000 scale

  const DetectedItemDto({required this.name, this.box});

  factory DetectedItemDto.fromJson(Map<String, dynamic> json) => DetectedItemDto(
        name: json['name'] as String,
        box: (json['box'] as List?)?.cast<num>().map((n) => n.toInt()).toList(),
      );
}

class DetectResponse {
  final List<DetectedItemDto> items;

  const DetectResponse({required this.items});

  factory DetectResponse.fromJson(Map<String, dynamic> json) => DetectResponse(
        items: (json['items'] as List? ?? [])
            .map((e) => DetectedItemDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
