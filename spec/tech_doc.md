# AI Reader 
`Flutter` application to listen `EPUB` books with generated voice using `Text-to-Speach` API backend (`FastAPI` `Python` app)
## `Flutter` app (`frontend`)
- App should have one screen and simple UI to upload EPUB files.
- During uploading and transforming the progress bar should appear with some short information (like 'Uploading file..', 'Generating voice..' and so on).
- When file is uploaded and read the new screen should appear with text. At same time the text should be uploaded to `backend` app and start to playback the generated voice and mark with background color text which is currently read (played), and text which is generating (with other color?).
- All not text elements should be omitted by now and reading should start from first chapter.
## `Python` app (`backend`)
- Python `FastAPI` app should use Python `3.13`.
- Voice generation should be transmitted in realtime with `Websocket` protocol or may be other alternative ways (batch download with some timeout to wait?)
### `Text-to-Speach` generation (`TTS`)
- TTS generation should use different methods, app should have configuration options to switch between them. Better to use open source libraries/`AI` models as  default method.
- All popular external `TTS` API providers and services could be integrated to be possible to use them (not sure which are better for now).
