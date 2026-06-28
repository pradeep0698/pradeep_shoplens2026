# C4 — Code: Tap vs Scan-All call chain

Shows the exact code-level call sequence for both live-scan paths, from camera frame to displayed product results.

```mermaid
sequenceDiagram
    title C4: Tap vs Scan-All — code-level call chain

    participant CAM   as Camera (on-device)
    participant MLKIT as MlKitDetectorService
    participant LSS   as LiveScanScreen._freezeAndIdentify()
    participant PP    as PipelineNotifier
    participant TAP   as TapIdentifyUseCase.identify()
    participant ANA   as AnalyzeImageUseCase.analyze()
    participant API   as AnalyzerApi (HTTP)
    participant BACK  as FastAPI /identify or /analyze
    participant CACHE as TTLCache (perceptual hash)
    participant GEM   as Gemini API
    participant GCS   as Google Cloud Storage
    participant LENS  as SerpAPI → Google Lens

    Note over CAM,MLKIT: Every camera frame (continuous stream)
    CAM->>MLKIT: CameraImage (NV21 / BGRA8888)
    MLKIT-->>LSS: List[DetectedObject] (bbox + labels, on-device)

    alt TAP on glowing dot
        Note over LSS: User taps a pulsing dot on screen
        LSS->>LSS: takePicture() → freeze frame
        LSS->>LSS: cropToMlKitBox(bytes, obj.boundingBox)
        LSS->>PP: identifyTappedObject(crop, mlkitContext)
        PP->>TAP: identify(croppedBytes, sessionId, ...)
        TAP->>API: POST /identify {image_data, mlkit_context}
        API->>BACK: identify(request)
        BACK->>CACHE: lookup _perceptual_cache_key(image, country)

        alt Cache HIT — same crop tapped within 30 min
            CACHE-->>BACK: (cached_products, cached_warnings)
            Note over BACK: Skips Gemini, GCS, and Lens entirely
            BACK-->>TAP: {products}
        else Cache MISS — first tap on this object
            par ThreadPoolExecutor (max_workers=2)
                BACK->>GEM: _describe_crop(jpeg) → "red Nike Air Max, white sole"
            and
                BACK->>GCS: _upload_gcs(jpeg) → public URL
            end
            BACK->>LENS: _google_lens(url, query=gemini_description)
            opt Lens returned nothing
                BACK->>LENS: _search_shopping(gemini_description)
            end
            BACK->>CACHE: store (products, warnings)
            BACK-->>TAP: {products}
        end

        TAP->>TAP: rankProducts() + _mergeProducts(existing, new)
        TAP-->>PP: first matched product name
        PP-->>LSS: state = PipelineStatus.success

    else SCAN ALL button pressed
        Note over LSS: User presses Scan All — no pre-selected crop
        LSS->>LSS: takePicture() → full frame (no crop)
        LSS->>PP: analyzeLoaded(mlkitContext)
        PP->>ANA: analyze(fullImageBytes, mimeType, ...)
        ANA->>API: POST /analyze {image_data, mlkit_context}
        API->>BACK: analyze(request)
        BACK->>GEM: detection prompt on full image → [{name, box}, ...]
        Note over BACK: Gemini returns bounding boxes for all objects
        loop Per detected object (capped at max_searches)
            BACK->>BACK: _crop_product(img_bytes, box)
            par per item
                BACK->>GEM: _describe_crop(crop)
            and
                BACK->>GCS: _upload_gcs(crop)
            end
            BACK->>LENS: _google_lens(url, query=gemini_description)
            opt Lens returned nothing
                BACK->>LENS: _search_shopping(gemini_description)
            end
        end
        BACK-->>ANA: {items, products, warnings}
        ANA-->>PP: products
        PP-->>LSS: state = PipelineStatus.success
    end
```

## Gemini call count comparison

| Path | Gemini calls | GCS uploads | Lens calls |
|------|:---:|:---:|:---:|
| **Tap (cache miss)** | 1 (describe crop) | 1 | 1 |
| **Tap (cache hit)** | 0 | 0 | 0 |
| **Scan All (N objects detected)** | 1 (detection) + N (describe per crop) | N | N |

## File locations

| Step | File |
|------|------|
| Camera frame → ML Kit | `mobile/lib/core/services/mlkit_detector_service.dart` |
| Bounding box overlay + tap handler | `mobile/lib/presentation/widgets/object_glow_overlay.dart` |
| Freeze, crop, route decision | `mobile/lib/presentation/screens/live_scan_screen.dart` |
| State machine + use-case dispatch | `mobile/lib/presentation/providers/pipeline_provider.dart` |
| Tap use-case (calls /identify) | `mobile/lib/domain/usecases/tap_identify_usecase.dart` |
| Analyze use-case (calls /analyze) | `mobile/lib/domain/usecases/analyze_image_usecase.dart` |
| HTTP client | `mobile/lib/data/sources/remote/analyzer_api.dart` |
| FastAPI routes | `services/ai-analyzer/main.py` |
| identify_crop / analyze_media | `services/ai-analyzer/analyzer.py` |
