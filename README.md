<img src="./assets/icon/app_icon.png" alt="App icon" width="64" height="64" />

# The Sports App

A Flutter app for watching live sports events with easy browsing, filtering, and personalized favorites management.

## About

The Sports App is a wrapper around the [streamed.pk API](https://streamed.pk/docs). This app **does not host or stream any content**. All streaming is provided by the streamed.pk service. The app serves as a user-friendly interface to browse and watch events available through that platform.

## Features

- **Live Event Browser** - Browse all live sports events in real-time
- **Popular Events** - Easily discover trending and popular sports events
- **Favorites** - Create a personalized list of your favorite teams and sports
- **Advanced Filtering** - Filter events by:
  - Event name (search)
  - Date (today's events only)
  - Popularity (popular events only)
- **Multiple Categories** - Browse events by:
  - Live Now (all current live events)
  - Popular (trending events)
  - Favorites (events featuring your favorite teams)
  - Individual Sports (browse by specific sport type)
- **Pull-to-Refresh** - Manually refresh event lists with a simple swipe down
- **Stream Refresh** - Reload live streams on demand
- **Picture-in-Picture (PiP) Mode** - Watch streams while browsing other content
- **Auto-Resume to Live** - Automatically jump to the live event on app resume
- **Stream Notifications** - Quick-access notification appears when streaming, allowing you to jump back into your stream from anywhere
- **Multi-Source Streams** - Support for multiple streaming sources per event

## Screenshots

| | |
|---|---|
| **Main Screen** ![Main Screen](https://private-user-images.githubusercontent.com/7417301/530780844-082d8ff3-16d0-4495-8d67-7f34b715c17f.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NjcwMjk5OTMsIm5iZiI6MTc2NzAyOTY5MywicGF0aCI6Ii83NDE3MzAxLzUzMDc4MDg0NC0wODJkOGZmMy0xNmQwLTQ0OTUtOGQ2Ny03ZjM0YjcxNWMxN2YucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI1MTIyOSUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNTEyMjlUMTczNDUzWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9NjY5MjZjZTM0NTJhY2ZkOGNiNzE4NzdkZjlmNmMyMjYzZjExNGRlZTZiMTcxZDRmZDM2NGMzYWRhYzk3NzZhNCZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.GdyO540tDCm7tyBqe4X3Aw56MgJqxKdljCbw-v7Gdaw) | **Sport Screen** ![Sport Screen](https://private-user-images.githubusercontent.com/7417301/530780859-1896fe8a-c39f-4427-80e2-833eb31f6ac1.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NjcwMjk5OTMsIm5iZiI6MTc2NzAyOTY5MywicGF0aCI6Ii83NDE3MzAxLzUzMDc4MDg1OS0xODk2ZmU4YS1jMzlmLTQ0MjctODBlMi04MzNlYjMxZjZhYzEucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI1MTIyOSUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNTEyMjlUMTczNDUzWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9MDA3NmQ4MjQ4ODFmMTFmYzNiZjkzYjQ5ZGZmN2M2YTJiZjllMDk4NDY4NDBjNjljNWRiNGU1ZjM0ZmFiMTFhNiZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.DvowIIf4emoaFQDbynhtxl0y2Lt3VdM8f4w8rkxSbsw) |
| **Stream Screen** ![Stream Screen](https://private-user-images.githubusercontent.com/7417301/530780892-bdb933cb-3b39-4365-ba63-58b8641cb080.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NjcwMjk5OTMsIm5iZiI6MTc2NzAyOTY5MywicGF0aCI6Ii83NDE3MzAxLzUzMDc4MDg5Mi1iZGI5MzNjYi0zYjM5LTQzNjUtYmE2My01OGI4NjQxY2IwODAucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI1MTIyOSUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNTEyMjlUMTczNDUzWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9N2Q0OGU2Y2I0ZDQxYmZkYjJjYmY5MWM0M2UwNzliOWNiMjI1OGNiMGMwZTliMjEwOGM0NTI1ZjJlMzNmNTA3MyZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.819I6M_XWsqdHNguBQFm5U7XmMpJpPuO763Def0LEYE) | **Settings Screen** ![Settings Screen](https://private-user-images.githubusercontent.com/7417301/530780885-28807fb3-a8ea-4a7b-94f0-8ffcffa42008.png?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NjcwMjk5OTMsIm5iZiI6MTc2NzAyOTY5MywicGF0aCI6Ii83NDE3MzAxLzUzMDc4MDg4NS0yODgwN2ZiMy1hOGVhLTRhN2ItOTRmMC04ZmZjZmZhNDIwMDgucG5nP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI1MTIyOSUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNTEyMjlUMTczNDUzWiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9ZWJkY2YzM2RkMDc2OWQwMzM5OWE2MDcwOWViZjhmZGUxNmU2NzY0Y2Q3Y2MxMDk1MTY5MGVmYWQwMjEyNTRjYiZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.hk3IDKuKoZsA4ZtwEzJ0sDNbx8_uEjWXtfwlMo665ko) |

## Known Issues

- **Multiple Taps to Start Stream** - Sometimes you may need to tap the video player multiple times to start playback
- **Stream Interruption** - Occasionally streams may stop playing and require manual restart
- **Live Status Limitation** - The "live" status indicator is based on the scheduled event start time. The streamed.pk API does not provide a real-time "live" flag, so this may not always reflect the actual streaming status

## Important Disclaimers

### Content & Streaming
This application is **not responsible for any content violations or streaming issues**. All streaming is handled by the [streamed.pk](https://streamed.pk) service. Any copyright or content-related concerns should be directed to streamed.pk, not this app.

### Feature Limitations
Any missing functionality in this app is a direct limitation of the streamed.pk API. This app implements all available features provided by the API. Additional features would require API-level support.

### Streaming Issues
All streaming-related problems (buffering, disconnections, quality issues, etc.) are on the streamed.pk service side. This app simply provides an interface to access their streams.

## Attribution

[App Icon](https://www.flaticon.com/free-icon/volleyball_4542458) made by [Freepik](https://www.flaticon.com/authors/freepik) from [www.flaticon.com](https://www.flaticon.com/).
