-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

-keep class com.google.ai.edge.litertlm.** { *; }
-keepclassmembers class com.google.ai.edge.litertlm.** {
    native <methods>;
    *jni*;
}
-dontwarn com.google.ai.edge.litertlm.**

