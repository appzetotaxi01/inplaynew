# React to Flutter AdMob Sync Implementation

This document outlines how the React (web) side needs to communicate with the Flutter app to display native AdMob Banner Ads.

## How it works

The Flutter app loads the React web app inside a `WebView`. A JavaScript handler named `updateAdPosition` has been injected into the web environment by Flutter. 

The React web app needs to calculate **when** and **where** (the Y-coordinate) the ad should be displayed on the screen, and send this data to Flutter using the `updateAdPosition` handler. When called, the Flutter app renders a native AdMob Banner *on top* of the WebView at the specified Y-coordinate.

## Implementation Details

Please add a function like the following to your React codebase. Call this function when your ad placement component mounts, scrolls, or unmounts.

```javascript
/**
 * Syncs the ad position with the Flutter App.
 * 
 * @param {string} pageName - The identifier for the page. Must be one of: 
 *                            'inplay-cinema', 'inplay-bhojpuri', or 'content-details'
 * @param {number} yPosition - The Y-coordinate on the screen where the ad should appear
 * @param {boolean} isVisible - true to show the ad, false to hide it
 * @param {number} width - (Optional) width of the ad, defaults to window innerWidth
 * @param {number} height - (Optional) height of the ad, defaults to 50 for banner
 */
function syncAdPosition(pageName, yPosition, isVisible, width = window.innerWidth, height = 50) {
  // Check if the Flutter InAppWebView handler is available
  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
    window.flutter_inappwebview.callHandler('updateAdPosition', {
      page: pageName,       
      y: yPosition,         
      width: width,         
      height: height,       
      visible: isVisible    
    });
  } 
  // Fallback for iOS WKWebView (if applicable in the future)
  else if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.updateAdPosition) {
    window.webkit.messageHandlers.updateAdPosition.postMessage({
      page: pageName, 
      y: yPosition, 
      width: width, 
      height: height, 
      visible: isVisible
    });
  } else {
    console.warn("Flutter WebView handlers not found. Ad sync skipped.");
  }
}
```

### Example Usage in a React Component

Here is an example of how you might use this in a React component that represents the ad container:

```javascript
import React, { useEffect, useRef } from 'react';

const AdBanner = ({ pageName }) => {
  const adContainerRef = useRef(null);

  useEffect(() => {
    // 1. Get the Y position of the ad container div
    const updatePosition = () => {
      if (adContainerRef.current) {
        const rect = adContainerRef.current.getBoundingClientRect();
        syncAdPosition(pageName, rect.top, true);
      }
    };

    // Initial position sync
    updatePosition();

    // (Optional) Add a scroll/resize listener if the ad container moves dynamically
    window.addEventListener('scroll', updatePosition);
    window.addEventListener('resize', updatePosition);

    // 2. Cleanup: Hide the ad when the component unmounts
    return () => {
      window.removeEventListener('scroll', updatePosition);
      window.removeEventListener('resize', updatePosition);
      
      // Send a -1000 Y-coordinate and false visibility to hide the ad
      syncAdPosition(pageName, -1000, false); 
    };
  }, [pageName]);

  // Render an empty container of the exact height (50px) to reserve the space in the web layout
  return (
    <div 
      ref={adContainerRef} 
      style={{ width: '100%', height: '50px', backgroundColor: 'transparent' }} 
    />
  );
};

export default AdBanner;
```

## Important Notes

1. **Page Names:** The `pageName` parameter must match exactly one of the keys defined in the Flutter app to work: 
   - `inplay-cinema`
   - `inplay-bhojpuri`
   - `content-details`
2. **Space Reservation:** The React side MUST render an empty `div` (or similar container) of `50px` height to "reserve" the physical space on the webpage. If space is not reserved, the native ad rendered by Flutter will overlay and cover up actual web content.
3. **Ad Unit IDs:** The Flutter app is currently configured with **REAL** AdMob Unit IDs (`ca-app-pub-9015405021941451/2275514393`). During local development, the ads may fail to load (Error Code 3) due to lack of inventory or test environment restrictions. This is normal. Look for `flutter: [AdSync]` in the Flutter console logs to verify that the position data is being successfully received from React.
