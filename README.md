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

| **Main Screen** | **Sport Screen** |
|---|---|
| ![Main Screen](https://i.imgur.com/DomICW1.png) | ![Sport Screen](https://i.imgur.com/ZoZfH3W.png) |

| **Stream Screen** | **Settings Screen** |
|---|---|
| ![Stream Screen](https://i.imgur.com/ctpVXaf.png) | ![Settings Screen](https://i.imgur.com/37bvujK.png) |

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
