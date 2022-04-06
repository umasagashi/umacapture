# Build

## Android

### OpenCV

TODO: Maybe just unzipping the archive is enough?

1. Download opencv-(version)-android-sdk.zip from [HERE](https://github.com/opencv/opencv/releases) and extract to any directory.
1. In Android Studio, File -> New -> Import Module -> specify `OpenCV-android-sdk/sdk` in extracted directory.
1. Make sure that the module name is `:sdk` (which should be default).
1. File -> Project Structure -> Dependencies -> app -> `+` button in Declared Dependencies -> 3 Moduel Dependency
1. Check the `sdk` checkbox and click ok.

## Windows

### OpenCV

1. Download opencv-(version)-vc14_vc15.exe from [HERE](https://github.com/opencv/opencv/releases) and extract to `windows/opencv`.
