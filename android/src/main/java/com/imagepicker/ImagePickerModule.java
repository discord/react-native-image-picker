package com.imagepicker;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.fragment.app.FragmentActivity;
import androidx.lifecycle.Lifecycle;

import com.facebook.react.bridge.ActivityEventListener;
import com.facebook.react.bridge.Callback;
import com.facebook.react.bridge.LifecycleEventListener;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.module.annotations.ReactModule;

import java.io.File;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static com.imagepicker.Utils.*;

import javax.annotation.Nullable;

@ReactModule(name = ImagePickerModule.NAME)
public class ImagePickerModule extends ReactContextBaseJavaModule implements ActivityEventListener, LifecycleEventListener {
    static final String NAME = "ImagePickerManager";

    // Public to let consuming apps hook into the image picker response
    public static final int REQUEST_LAUNCH_IMAGE_CAPTURE = 13001;
    public static final int REQUEST_LAUNCH_VIDEO_CAPTURE = 13002;
    public static final int REQUEST_LAUNCH_LIBRARY = 13003;

    private Uri fileUri;

    final ReactApplicationContext reactContext;

    Callback callback;

    Options options;
    Uri cameraCaptureURI;
    @Nullable
    UUID identifier;

    // Pre-registered launchers for Activity Result API
    private ActivityResultLauncher<Intent> cameraLauncher;
    private ActivityResultLauncher<Intent> libraryLauncher;
    private FragmentActivity currentFragmentActivity;

            public ImagePickerModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
        this.reactContext.addActivityEventListener(this);
        this.reactContext.addLifecycleEventListener(this);
    }

    @Override
    public void onHostResume() {
        Activity currentActivity = getCurrentActivity();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
            currentActivity instanceof FragmentActivity fragmentActivity) {
            initializeLaunchers(fragmentActivity);
        }
    }

    @Override
    public void onHostPause() {}

    @Override
    public void onHostDestroy() {}

    @Override
    public void initialize() {
        super.initialize();
    }


    @NonNull
    @Override
    public String getName() {
        return NAME;
    }

        /**
     * Initialize launchers when we have access to a FragmentActivity during proper lifecycle
     */
        private void initializeLaunchers(FragmentActivity activity) {
        if (activity == null) return;

        // Only register if we haven't already for this activity
        if (currentFragmentActivity != activity || cameraLauncher == null) {
            try {
                // Check if we can register (activity must be at least CREATED)
                if (activity.getLifecycle().getCurrentState().isAtLeast(Lifecycle.State.CREATED)) {
                    currentFragmentActivity = activity;

                    cameraLauncher = activity.registerForActivityResult(
                        new ActivityResultContracts.StartActivityForResult(),
                        result -> {
                            int requestCode = REQUEST_LAUNCH_IMAGE_CAPTURE;
                            if (this.options != null && this.options.mediaType.equals(mediaTypeVideo)) {
                                requestCode = REQUEST_LAUNCH_VIDEO_CAPTURE;
                            }
                            onActivityResult(activity, requestCode, result.getResultCode(), result.getData());
                        }
                    );

                    libraryLauncher = activity.registerForActivityResult(
                        new ActivityResultContracts.StartActivityForResult(),
                        result -> {
                            onActivityResult(activity, REQUEST_LAUNCH_LIBRARY, result.getResultCode(), result.getData());
                        }
                    );

                }
            } catch (IllegalStateException e) {
                // Failed to register - activity in wrong state
            }
        }
    }

    @Override
    public void onActivityResult(Activity activity, int requestCode, int resultCode, Intent data) {
        // onActivityResult is called even when ActivityNotFoundException occurs
        if (!isValidRequestCode(requestCode) || (this.callback == null)) {
            return;
        }

        if (resultCode != Activity.RESULT_OK) {
            if (requestCode == REQUEST_LAUNCH_IMAGE_CAPTURE) {
                deleteFile(fileUri);
            }
            callback.invoke(getCancelMap());
            this.callback = null;
            return;
        }

        switch (requestCode) {
            case REQUEST_LAUNCH_IMAGE_CAPTURE:
                if (options.saveToPhotos) {
                    saveToPublicDirectory(cameraCaptureURI, identifier, reactContext, "photo");
                }

                onAssetsObtained(Collections.singletonList(fileUri));
                break;

            case REQUEST_LAUNCH_LIBRARY:
                onAssetsObtained(collectUrisFromData(data));
                break;

            case REQUEST_LAUNCH_VIDEO_CAPTURE:
                if (options.saveToPhotos) {
                    saveToPublicDirectory(cameraCaptureURI, identifier, reactContext, "video");
                }

                onAssetsObtained(Collections.singletonList(fileUri));
                break;
        }
    }

    @ReactMethod
    public void launchCamera(final ReadableMap options, final Callback callback) {
        if (!isCameraAvailable(reactContext)) {
            callback.invoke(getErrorMap(errCameraUnavailable, null));
            return;
        }

        final Activity currentActivity = getCurrentActivity();
        if (currentActivity == null) {
            callback.invoke(getErrorMap(errOthers, "Activity error"));
            return;
        }

        if (!isCameraPermissionFulfilled(reactContext, currentActivity)) {
            callback.invoke(getErrorMap(errOthers, cameraPermissionDescription));
            return;
        }

        this.callback = callback;
        this.options = new Options(options);

        if (this.options.saveToPhotos && Build.VERSION.SDK_INT <= Build.VERSION_CODES.P && !hasPermission(currentActivity)) {
            callback.invoke(getErrorMap(errPermission, null));
            this.callback = null;
            return;
        }

        int requestCode;
        File file;
        Intent cameraIntent;

        identifier = UUID.randomUUID();

        if (this.options.mediaType.equals(mediaTypeVideo)) {
            requestCode = REQUEST_LAUNCH_VIDEO_CAPTURE;
            cameraIntent = new Intent(MediaStore.ACTION_VIDEO_CAPTURE);
            cameraIntent.putExtra(MediaStore.EXTRA_VIDEO_QUALITY, this.options.videoQuality);
            if (this.options.durationLimit > 0) {
                cameraIntent.putExtra(MediaStore.EXTRA_DURATION_LIMIT, this.options.durationLimit);
            }
            file = createFile(reactContext, identifier, "mp4");
            cameraCaptureURI = createUri(file, reactContext);
        } else {
            requestCode = REQUEST_LAUNCH_IMAGE_CAPTURE;
            cameraIntent = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            file = createFile(reactContext, identifier, "jpg");
            cameraCaptureURI = createUri(file, reactContext);
        }

        if (this.options.useFrontCamera) {
            setFrontCamera(cameraIntent);
        }

        fileUri = Uri.fromFile(file);
        cameraIntent.putExtra(MediaStore.EXTRA_OUTPUT, cameraCaptureURI);
        cameraIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);

        try {
            if (cameraLauncher != null) {
                cameraLauncher.launch(cameraIntent);
            } else {
                currentActivity.startActivityForResult(cameraIntent, requestCode);
            }
        } catch (ActivityNotFoundException e) {
            callback.invoke(getErrorMap(errOthers, e.getMessage()));
            this.callback = null;
        } catch (Exception e) {
            callback.invoke(getErrorMap(errOthers, "Failed to launch camera: " + e.getMessage()));
            this.callback = null;
        }
    }

    @ReactMethod
    public void launchImageLibrary(final ReadableMap options, final Callback callback) {
        final Activity currentActivity = getCurrentActivity();
        if (currentActivity == null) {
            callback.invoke(getErrorMap(errOthers, "Activity error"));
            return;
        }

        this.callback = callback;
        this.options = new Options(options);

        int requestCode;
        Intent libraryIntent;
        requestCode = REQUEST_LAUNCH_LIBRARY;

        boolean isSingleSelect = this.options.selectionLimit == 1;
        boolean isPhoto = this.options.mediaType.equals(mediaTypePhoto);
        boolean isVideo = this.options.mediaType.equals(mediaTypeVideo);
        boolean isMixed = this.options.mediaType.equals(mediaTypeMixed);

        if(isSingleSelect && (isPhoto || isVideo)) {
            libraryIntent = new Intent(Intent.ACTION_PICK);
        } else {
            libraryIntent = new Intent(Intent.ACTION_GET_CONTENT);
            libraryIntent.addCategory(Intent.CATEGORY_OPENABLE);
        }

        if(!isSingleSelect) {
            libraryIntent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        }

        if(isPhoto) {
            libraryIntent.setType("image/*");
        } else if (isVideo) {
            libraryIntent.setType("video/*");
        } else if (isMixed) {
            libraryIntent.setType("*/*");
            libraryIntent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"image/*", "video/*"});
        } else {
            libraryIntent.setType("*/*");
        }

        Intent chooserIntent = Intent.createChooser(libraryIntent, null);
        try {
            if (libraryLauncher != null) {
                libraryLauncher.launch(chooserIntent);
            } else {
                currentActivity.startActivityForResult(chooserIntent, requestCode);
            }
        } catch (ActivityNotFoundException e) {
            callback.invoke(getErrorMap(errOthers, e.getMessage()));
            this.callback = null;
        } catch (Exception e) {
            callback.invoke(getErrorMap(errOthers, "Failed to launch library: " + e.getMessage()));
            this.callback = null;
        }
    }



    void onAssetsObtained(List<Uri> fileUris) {
        try {
            callback.invoke(getResponseMap(fileUris, identifier, options, reactContext));
        } catch (RuntimeException exception) {
            callback.invoke(getErrorMap(errOthers, exception.getMessage()));
        } finally {
            callback = null;
        }
    }


    @Override
    public void onNewIntent(Intent intent) { }

    @Override
    public void invalidate() {
        super.invalidate();
        // Clean up launchers to prevent memory leaks
        if (cameraLauncher != null) {
            cameraLauncher.unregister();
            cameraLauncher = null;
        }
        if (libraryLauncher != null) {
            libraryLauncher.unregister();
            libraryLauncher = null;
        }
        if (currentFragmentActivity != null) {
            currentFragmentActivity = null;
        }
    }
}
