# ARKit Spatial Hand Interaction

This project demonstrates a robust, true 3D hand-tracking and object-interaction engine built using Apple's **ARKit**, **Vision**, and **SceneKit** frameworks. It allows users to physically reach into augmented reality, grab virtual objects out of the air using a pinch gesture, and drag them through 3D space with zero external controllers.

## How It Works: The Technology Stack

The interaction pipeline solves the complex problem of mapping a user's physical hand into a mathematical 3D coordinate system in real-time. It accomplishes this in three distinct stages:

### 1. Vision: 2D Hand Tracking & Gesture Recognition
The app uses Apple's Machine Learning `Vision` framework (`VNDetectHumanHandPoseRequest`) to analyze the live camera feed 60 times a second.
* **The Interaction Point:** It extracts the exact `(x, y)` 2D pixel coordinate of the user's **Palm Center** (calculated as the midpoint between the Wrist and Middle Knuckle). The palm is used instead of fingertips because its larger surface area provides significantly cleaner and more stable LiDAR readings.
* **The Pinch Gesture:** It simultaneously monitors the physical distance between the `thumbTip` and `indexTip`. It uses a **hysteresis** threshold (a wider margin for opening vs. closing) and an 8-frame **time-based debounce** mechanism. This ensures that the pinch is completely immune to micro-flickering or sudden camera tracking noise.

### 2. LiDAR & SceneKit: The True 3D Unprojection
Once we have the 2D pixel of the palm, we must map it into the real physical room.
* **The Raycast (Direction):** We use `SceneKit` to draw an invisible mathematical line starting from the iPad camera lens and shooting perfectly through the 2D palm pixel on the screen out into the real world.
* **The LiDAR Sensor (Distance):** We query the iPad's raw LiDAR sensor (`frame.sceneDepth`) for that exact pixel. The LiDAR fires a photon and measures the Time-of-Flight (ToF) to return the absolute physical distance to the user's hand (e.g., 0.45 meters).
* **The 3D Coordinate:** By walking exactly 0.45 meters down the SceneKit raycast line, we determine the hand's exact `(X, Y, Z)` true spatial coordinate in the room. A Yellow Sphere is placed here to visualize the tracking.

*(Note: LiDAR has a physical hardware blindspot for objects closer than ~30cm. The app detects this and drops a Red warning cursor at a fixed 30cm depth if the hand enters the blindspot).*

### 3. The Forgiving Physics Engine (Cylindrical Buffer)
Humans have very poor absolute depth perception when looking at a flat iPad screen. If the app required the user's hand to *perfectly* intersect the 3D Apple to grab it, it would be incredibly frustrating.
To solve this, the app uses a **Cylindrical Bounding Box** around interactable objects.
* **Aim Check (X & Y Axis):** The app checks if the hand is within 9 centimeters of the object's center (the width of the cylinder).
* **Depth Check (Z Axis):** The app provides a massive 30-centimeter depth buffer (15cm in front of and behind the object). 
If the hand's 3D coordinate is mathematically inside this cylinder, it counts as a physical collision.

## The Visual Feedback Loop

To make this complex math feel intuitive to the user, the app uses dynamic color-coding:
1. **Yellow Cursor:** The hand is actively tracked in 3D space, but is not interacting with anything.
2. **Green Cursor (Hover State):** The user's hand has physically intersected the Cyan Cylinder buffer. If they pinch now, a grab is guaranteed.
3. **Orange Buffer (Grabbed State):** The user has pinched while Green. The grabbed object's buffer turns Orange to indicate it is actively being held and dragged through space.
4. **Red Cursor (Blindspot):** The user's hand is too close to the iPad lens (< 30cm).

## Core Apple Frameworks & Classes

The interaction engine heavily relies on three of Apple's spatial computing frameworks. Here is a breakdown of the core classes used:

### ARKit (Augmented Reality & Sensors)
* `ARSCNView`: The main view that merges the live camera feed with the 3D SceneKit rendering environment.
* `ARFrame`: Represents a single snapshot of the camera feed. We extract two crucial pieces of data from it every 60th of a second:
  * `frame.capturedImage`: The raw 2D pixel buffer sent to the Vision model to find the hand.
  * `frame.sceneDepth`: The raw LiDAR depth map used to find the physical distance of the hand.
* `ARAnchor`: Used to lock static virtual objects (like the Apples) to physical locations in the real world. (Note: The hand cursor does *not* use an anchor because it is constantly moving).

### Vision (Machine Learning)
* `VNDetectHumanHandPoseRequest`: The ML model request that scans the 2D image for human hands.
* `VNHumanHandPoseObservation`: The result returned by the ML model. It contains the 21 `VNRecognizedPoint` coordinates (joints) of the hand. We specifically extract `.wrist`, `.middleMCP`, `.thumbTip`, and `.indexTip`.

### SceneKit (3D Rendering & Math)
* `SCNNode`: The fundamental building block of 3D space. Every object (the Apple, the Hand Cursor, the Coordinate Labels) is an `SCNNode`.
* `SCNSphere`: The 3D geometry used to draw the Yellow/Green/Red hand cursor.
* `SCNCylinder`: The 3D geometry used to draw the translucent forgiving physics buffer around the Apple.
* `SCNText` & `SCNBillboardConstraint`: Used to render the floating 3D spatial coordinates that mathematically rotate to always face the user's camera.
* `sceneView.unprojectPoint()`: The critical SceneKit mathematical function that combines a 2D screen coordinate with a Z-depth (from LiDAR) to output a true 3D `(X, Y, Z)` coordinate in the room.
