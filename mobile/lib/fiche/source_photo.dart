import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Photo du visage par l'appareil photo du téléphone. Remplaçable dans les tests.
class SourcePhoto {
  const SourcePhoto();

  /// Renvoie l'image JPEG, ou null si l'agent a annulé. Taille réduite
  /// (800 px, qualité 85) : suffisant pour une fiche, léger à envoyer.
  Future<Uint8List?> prendre() async {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      maxWidth: 800,
      maxHeight: 1000,
      imageQuality: 85,
    );
    return photo?.readAsBytes();
  }
}
