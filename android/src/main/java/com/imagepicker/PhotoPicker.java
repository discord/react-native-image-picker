package com.imagepicker;

import static com.imagepicker.Utils.*;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.ext.SdkExtensions;
import android.provider.MediaStore;

import androidx.activity.result.PickVisualMediaRequest;
import androidx.activity.result.contract.ActivityResultContracts;

import javax.annotation.Nullable;

/**
 * Integrates with the system Photo Picker.
 *
 * All of this is a Discord-fork-only implementation.
 *
 * https://developer.android.com/training/data-storage/shared/photo-picker
 */
final class PhotoPicker {
    @Nullable
    private static Boolean isAvailable;

    private PhotoPicker() {}

    /**
     * Used to avoid asking for the Images permission.
     *
     * When we're using the Photo Picker, we actually don't have to ask anymore!
     * We also cache the value because we expose it as a constant.
     */
    static boolean isAvailable(Context context) {
        if (isAvailable == null) {
            // True when either the framework Photo Picker or the Google Play services backport is present.
            isAvailable = ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(context);
        }
        return isAvailable;
    }

    // Mirrored by canUseAndroidPhotoPicker in src/index.ts.
    static boolean shouldUse(Context context, Options options) {
        if (!options.enableAndroidPhotoPicker) {
            return false;
        }

        // forceGetContent is used for Meta Quest, because they don't have the Photo Picker.
        if (options.forceGetContent) {
            return false;
        }

        // Photo Picker doesn't support files (obviously) so we can't use it for `any`.
        if (options.mediaType.equals(mediaTypeAny)) {
            return false;
        }

        return isAvailable(context);
    }

    static Intent createIntent(Activity activity, Options options) {
        ActivityResultContracts.PickVisualMedia.VisualMediaType visualMediaType;
        if (options.mediaType.equals(mediaTypePhoto)) {
            visualMediaType = ActivityResultContracts.PickVisualMedia.ImageOnly.INSTANCE;
        } else if (options.mediaType.equals(mediaTypeVideo)) {
            visualMediaType = ActivityResultContracts.PickVisualMedia.VideoOnly.INSTANCE;
        } else {
            visualMediaType = ActivityResultContracts.PickVisualMedia.ImageAndVideo.INSTANCE;
        }

        PickVisualMediaRequest request = new PickVisualMediaRequest.Builder()
                .setMediaType(visualMediaType)
                .build();

        if (options.selectionLimit == 1) {
            return new ActivityResultContracts.PickVisualMedia().createIntent(activity, request);
        }

        // A selection limit of 0 (or less) means no limit.
        // MediaStore.getPickImagesMaxLimit() determines the maximum limit.
        int maxItems = getMaxLimit();
        if (options.selectionLimit > 1) {
            maxItems = Math.min(options.selectionLimit, maxItems);
        }
        return new ActivityResultContracts.PickMultipleVisualMedia(maxItems).createIntent(activity, request);
    }

    @SuppressLint("NewApi")
    private static int getMaxLimit() {
        boolean hasFrameworkPicker = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                        && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2);
        return hasFrameworkPicker ? MediaStore.getPickImagesMaxLimit() : Integer.MAX_VALUE;
    }
}
