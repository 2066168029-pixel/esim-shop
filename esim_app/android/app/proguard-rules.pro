# Keep rules for the Linksfield eSIM Manager SDK (droidlib-v1.2.0.aar).
#
# The AAR ships R8-processed classes. Its public surface has two halves, and
# both must survive the app's own shrinker pass or `LpadBleBridge` cannot link:
#
#   1. com.linksfield.lpad.**        the protocol stack itself
#   2. android_.telephony.euicc.**   the SDK's shaded copy of the platform
#                                    eUICC DTOs (trailing underscore is part of
#                                    the package name, not a typo)
#
# Half of #2 is also referenced by name from generated protobuf code inside the
# AAR, so renaming it breaks the SDK at runtime rather than at compile time --
# the worst kind of failure to debug on a device.

-keep class com.linksfield.lpad.** { *; }
-keep class android_.telephony.euicc.** { *; }
-keep class android_.service.euicc.** { *; }
-keep class android_.service.carrier.** { *; }
-keep class com.android_.internal.** { *; }

# gRPC: the SDK's stubs are looked up reflectively by grpc-stub.
-keep class io.grpc.** { *; }
-dontwarn io.grpc.**

# Kotlin metadata for the SDK's data classes (copy/asStub generated methods).
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*

# The bridge is called from Flutter over a MethodChannel handle, so R8 cannot
# see the call edges. Keep the entry points explicitly.
-keep class com.esimshop.esim_app.LpadBleBridge { public *; }
-keep class com.esimshop.esim_app.LpadChannel { *; }
-keep class com.esimshop.esim_app.LpadError { *; }

# Reference the shaded shadow class once so R8 marks it live.
-keepnames class android_.telephony.euicc.DownloadableSubscription$Builder

# ---------------------------------------------------------------------------
# Retrofit / OkHttp / RxJava
#
# The SDK reaches the operator's SM-DP+ over its own Retrofit client, and ships
# those libraries R8-processed and obfuscated (`tg1`, `e3.a`). Retrofit builds
# call adapters reflectively from generic signatures and annotations, so
# shrinking them yields, at *runtime* only:
#
#   Unable to create call adapter for class tg1 for method e3.a
#
# which is what `enable` hit on 2026-10-27: reading profiles worked (pure BLE),
# enabling did not (HTTP). Keep the whole stack plus its generic signatures.
-keep class retrofit2.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class rx.** { *; }
-keep class io.reactivex.** { *; }

-keepattributes Signature,Exceptions,InnerClasses,EnclosingMethod
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations
-keepattributes AnnotationDefault

-keepclasseswithmembers class * {
    @retrofit2.http.* <methods>;
}
-keepclasseswithmembers interface * {
    @retrofit2.http.* <methods>;
}

# Retrofit resolves CallAdapter.Factory and Converter.Factory via ServiceLoader.
-keep class * implements retrofit2.CallAdapter$Factory { *; }
-keep class * implements retrofit2.Converter$Factory { *; }

-dontwarn retrofit2.**
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn rx.**
-dontwarn io.reactivex.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# ---------------------------------------------------------------------------
# Flutter plugins that rely on reflection
#
# Turning R8 on (which had never actually been enabled before) broke the QR
# scanner with:
#
#   MethodChannel#dev.steenbakker.mobile_scanner/scanner/method
#   NullPointerException: 'java.lang.Class java.lang.Object.getClass()'
#   on a null object reference
#
# mobile_scanner resolves its analyser/provider classes reflectively, so the
# plugin package has to survive intact.
-keep class dev.steenbakker.mobile_scanner.** { *; }
-dontwarn dev.steenbakker.mobile_scanner.**
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.mlkit.**

# Flutter's own plugin registry is looked up by name from the generated
# GeneratedPluginRegistrant.
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.engine.plugins.** { *; }
