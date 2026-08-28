I'd like to build a camera app for my macbook. Mimic the functionalities of an iphone camera app. 
- It should have Photo and Video mode, 
- Should have easy onscreen settings to adjust the photo quality and format and video resolution and fps just like in an iphone camera app
- Should have focus/exposure adjustment functionalities while tapping the image
- Should have easy access and preview to the photos taken
- It saves the medias in `~/Photos` (default) or in the photos library 
- For audio, it defaults to the system mic, but allow switching between different devices if connected to, treat system audio output devices as audio sources as well, that is we can record a video with system audio output as the audio track
- Allow audio muxing, which is to mix system output and multiple input devices, this can be tuned in the settings page
- It allows switching between different camera devices, also treat computer screen as a camera device
- Add an option to do screen recordings with pip camera view
- It has a dedicated settings page that allows change of video/photo formats, media locations, audio muxing settings 

You can use swift (and C++/OC if you need to). Include unit tests. After building the app, thoroughly test it, fix any errors, bugs, and discrepencies in functionalities.

The xcode app is Xcode-beta.app

See improv.md for improvements