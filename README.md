# SummitCodeSamples
Code samples from **Summit**, a climbing game built on Roblox.  
All scripts are written in **Lua** and demonstrate gameplay systems, interaction logic, and inventory management.

## My Role
I was responsible for implementing:
- **The rope climbing system** — allowing smooth attachment, movement, and detachment from ropes.
- **The backpack / inventory system** — managing item storage, interaction, and synchronization between client and server.
- **The class and player state handler** — handling stamina, item usage, and interaction states.

### Rope System
- **RopeHandler.lua** – Handles rope spawning, interaction logic, and synchronization.
- **RopeClimbHandler.lua** – Manages player movement and camera transitions while climbing ropes.

### Inventory System
- **InventoryHandler.lua** – Core server-side inventory management, including item pickup, dropping, and syncing.
- **InventoryClient.lua** – Client logic for UI updates, prompt handling, and interaction events.
- **BackpackInventoryHandler.lua** – Server module for managing backpack-specific inventories and slot logic.

### Player Systems
- **ClassHandler.lua** – Manages player stats, classes, and ability cooldowns.
- **ClimbingSystem.lua** – Handles stamina consumption, climbing animation states, and attachment logic.