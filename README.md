# 📸 Open Cámara

**Open Cámara** is a premium, minimalist camera application built with Flutter. It combines a sleek "Glassmorphism" UI with professional-grade photography features.

## ✨ Features

### 🎨 User Interface (UI)
*   **Design**: Modern, dark-themed UI with Glassmorphism effects (blur, transparency).
*   **Animations**: Smooth transitions between Camera and Review modes using `AnimatedSwitcher` and `AnimatedOpacity`.
*   **Dynamic Controls**: Toolbars and sliders fade in/out based on user interaction to maximize the viewfinder area.
*   **Custom Icon**: Minimalist, AI-generated premium camera lens icon.

### 📷 Camera Capabilities
*   **Aspect Ratios**: Toggle between **1:1** (Square) and **3:4** (Standard).
*   **Zoom**: Smooth pinch-to-zoom and slider control (1.0x to max device zoom).
*   **Exposure**: Manual exposure compensation slider with lock capability.
*   **Focus**: Tap-to-focus with visual indicator and focus locking.
*   **Flash Modes**: Support for Auto, On, Off, and Torch.
*   **Switch Camera**: Seamlessly toggle between front and rear lenses.

### 🖼️ Image Processing & Review
*   **Review Screen**: Instant preview of captured photos with options to:
    *   **Share**: Native system share sheet (`share_plus`).
    *   **Edit**: Open in default external editor (`open_filex`).
    *   **Save**: Save directly to device gallery (`gal`).
    *   **Delete**: Discard and return to camera immediately.
*   **Filters**: Support for custom color styles via `style.xml` (LUT-based color grading simulation).

## 🛠️ Technology Stack

*   **Framework**: [Flutter](https://flutter.dev/) (Dart)
*   **Core Dependencies**:
    *   `camera`: Hardware camera access.
    *   `gal`: Gallery saving capabilities.
    *   `share_plus`: Sharing content.
    *   `open_filex`: Opening files externally.
    *   `path_provider` & `path`: File system management.
    *   `xml`: Parsing style configurations.
    *   `flutter_launcher_icons`: Managing app icons.

## 🚀 Getting Started

### Prerequisites
*   Flutter SDK (3.10.4 or higher recommended)
*   Android Studio / VS Code with Flutter extensions
*   Wait for dependencies to install: `flutter pub get`

### Installation

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/yourusername/open_camara.git
    cd open_camara
    ```

2.  **Install dependencies**:
    ```bash
    flutter pub get
    ```

3.  **Run the app**:
    ```bash
    flutter run
    ```

### Android Configuration
*   **Permissions**: The `AndroidManifest.xml` is pre-configured with `CAMERA` and `RECORD_AUDIO` permissions.
*   **Label**: The app name is set to "Open Cámara".

### iOS Configuration
*   **Info.plist**: `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` are configured for privacy compliance.

## ⚙️ Image Processing Pipeline

The app uses a robust, isolate-based image processing pipeline to ensure high performance without blocking the UI thread.

### Flow Architecture
1.  **Capture**: The camera sensor captures the raw image data.
2.  **Configuration**: `StyleService` loads the active filter profile (XML).
3.  **Isolate Execution**: `ImageService.processImage` spawns a background isolate to handle heavy computation.
    *   **Decode**: Converts bytes to an editable bitmap.
    *   **Crop**: Smart cropping to match the selected aspect ratio (1:1 or 3:4) centering the image.
    *   **Advanced Filtering**: Applies a chain of pixel-level manipulations:
        *   *Basic*: Brightness, Contrast, Saturation, Gamma.
        *   *Color Balance*: Independent RGB channel adjustment.
        *   *Vibrance*: Boosts muted colors without oversaturating skin tones (`saturation` tweak).
        *   *Temperature*: Shifts white balance (Warm/Cool).
        *   *Tone Mapping*: Shadows & Highlights recovery (Luma-based masking).
        *   *Tinting*: Overlay color blending for artistic effects.
4.  **Encoding**: Compresses the result to High-Quality JPG.
5.  **Output**: Saves to disk and notifies the Gallery.

### Custom Filters (`style.xml`)
The processing engine is data-driven. You can define custom "Looks" by modifying `style.xml`.
 Example structure:
```xml
<StyleConfig>
    <Brightness>0.1</Brightness>
    <Contrast>1.2</Contrast>
    <RGB>
        <Red>1.05</Red>
        <Blue>0.95</Blue>
    </RGB>
    <Tint>
        <Color>#FF0000</Color>
        <Opacity>0.1</Opacity>
    </Tint>
</StyleConfig>
```

## 📂 Project Structure

```
lib/
├── main.dart             # Application entry point
├── pages/
│   └── camera_page.dart  # Core camera logic and UI implementation
├── services/
│   ├── image_service.dart # Handles image saving and processing
│   └── style_service.dart # Manages custom style parsers (filters)
└── widgets/              # (Potential future refactor for UI components)
```

## 📝 Key Files Description

*   **`camera_page.dart`**: The heart of the app. Contains the `CameraController` logic, gesture detectors for focus/zoom, and the entire `Stack`-based UI layout including animations.
*   **`style_service.dart`**: Responsible for reading `assets/style.xml` to apply color configurations (Work in progress for advanced filters).

## 🎨 Asset Generation

*   **Icons**: Modifying `assets/icon.png` and running `dart run flutter_launcher_icons` updates the app icon for all platforms.

---
Built with ❤️ using Flutter.
