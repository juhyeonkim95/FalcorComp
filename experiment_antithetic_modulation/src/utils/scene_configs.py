import numpy as np

def get_scene_image_size(scene_name):
    if "cornell" in scene_name:
        return (1024, 1024)
    if "navigate" in scene_name:
        return (1024, 1024)
    elif "staircase" in scene_name:
        return (1024, 1024)
    return (1920, 1080)

def get_min_max_dist(scene_name):
    if "cornell" in scene_name:
        k = 7.75
        return (9 + k, 12 + k)
    elif "navigate" in scene_name:
        return (15, 30)
    elif "nlos" in scene_name:
        # return (19.8, 20.8)
        k = 6.8*2
        return (2 + k, 4 + k)
    elif "kitchen" in scene_name:
        return (17, 20)
    elif "veach-ajar" in scene_name:
        return (19, 21)
    elif "spaceship" in scene_name:
        return (12, 24)
    elif "killeroo" in scene_name:
        return (500, 2000)
    elif "bistro" in scene_name:
        return (60, 60)
    elif "living-room-2" in scene_name:
        return (10, 20)
    elif "bedroom" in scene_name:
        # return (12, 12)
        return (15, 15)
    elif "staircase" in scene_name:
        return (24, 24)

    return (10, 10)

def get_target_index(scene_name):
    if "cornell" in scene_name:
        return 100
    elif "kitchen" in scene_name:
        return 0
    elif "veach-ajar" in scene_name:
        return 0
    elif "spaceship" in scene_name:
        return 0
    elif "killeroo" in scene_name:
        return 0
    elif "bistro" in scene_name:
        return 0
    elif "living-room-2" in scene_name:
        return 0
    elif "staircase" in scene_name:
        return 0
    return 0

def get_laser_direction(pos, target):
    pos_numpy = np.array(pos)
    tar_numpy = np.array(target)
    direction = tar_numpy - pos_numpy
    direction /= np.linalg.norm(direction)

    return direction.tolist()

def get_point_light_scaler(scene_name):
    if "cornell" in scene_name:
        return 50
    if "kitchen" in scene_name:
        return 3
    return 10

def get_time_limits(scene_name):
    if "cornell" in scene_name:
        return [1, 2, 4, 8, 16, 32]
    elif "veach-ajar" in scene_name:
        return [1, 2, 4, 8, 16, 32, 64, 128]
    elif "kitchen" in scene_name:
        return [1, 2, 4, 8, 16, 32, 64, 128, 256]
    return [1]
    
def get_spp_limits(scene_name):
    if "cornell" in scene_name:
        return [1, 2, 4, 8, 16, 32]
    elif "veach-ajar" in scene_name:
        return [1, 2, 4, 8, 16, 32, 64, 128]
    elif "kitchen" in scene_name:
        return [1, 2, 4, 8, 16, 32, 64, 128, 256]
    return [1]

def get_laser_info(scene_name):
    
    laser_position = (0.0, 1.7, 6.8)
    laser_direction = (0.0, 0.0, -1.0)
    laser_power = (100, 100, 100)
    
    if "cornell" in scene_name:
        laser_position = (0.0, 1.7, 6.8)
        laser_direction = (0.0, 0.0, -1.0)
        laser_power = (170, 120, 40)
    elif "dining" in scene_name:
        laser_position = (-0.587, 2.752, 9.7)
        laser_target = (-0.587, 2.752, 8.7)
        # laser_direction = (-0.587, 2.752, 8.7)
        laser_power = (10000, 10000, 10000)
    elif "kitchen" in scene_name:
        laser_position = (1.211005, 1.804748, 3.852392)
        laser_target = (0.772905, 1.763078, 2.95443)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (1000, 1000, 1000)
    elif "veach-ajar" in scene_name:
        laser_position = (4.054023, 1.616475, -2.306524)
        laser_target = (3.064008, 1.584177, -2.443737)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (1000, 1000, 1000)
    elif "spaceship" in scene_name:
        laser_position = (-0.519662, 0.817007, 3.824385)
        # laser_target = (-0.383709, 0.765330, 2.835019)
        laser_target = (-0.383709, 0.765330, 2.835019)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (10000, 10000, 10000)
    elif "killeroo" in scene_name:
        laser_position = (396.0, 54.0, 30)
        # laser_target = (-0.383709, 0.765330, 2.835019)
        laser_target = (395.0, 54.0, 30)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (100000, 100000, 100000)
    elif "bistro" in scene_name:
        # laser_position = (-15.4843397, 2.14625645, 2.03)
        # laser_target = (-14.9759874, 2.13, 1.17)
        laser_position = (-9.70, 2.5, 4.3)
        laser_target = (-9.27, 2.32, 3.41)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (1000000, 1000000, 1000000)
    elif "nlos-navigate" in scene_name:
        laser_position = (0.0, 1.0, 6.8)
        laser_direction = (0.0, 0.0, -1.0)
        laser_power = (100, 100, 100)
    elif "nlos" in scene_name:
        laser_position = (0.0, 1.0, 6.8)
        laser_direction = (0.0, 0.0, -1.0)
        laser_power = (170, 120, 40)
        # laser_position = (-15.4843397, 2.14625645, 2.03)
        # laser_target = (-14.9759874, 2.13, 1.17)
        # laser_direction = get_laser_direction(laser_position, laser_target)
        # laser_power = (100000, 100000, 100000)
    elif "bedroom" in scene_name:
        laser_position = (3.4558, 1.212433, 3.298965)
        laser_target = (2.698842, 1.195447, 2.645468)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (100, 100, 100)
    elif "staircase" in scene_name:
        laser_position = (0.032421, 1.526728, 4.88197)
        laser_target = (0.024775, 1.571783, 3.883015)
        laser_direction = get_laser_direction(laser_position, laser_target)
        laser_power = (1000, 1000, 1000)

    laser_position = np.array(laser_position, dtype=float)
    laser_direction = np.array(laser_direction, dtype=float)
    laser_power = np.array(laser_power, dtype=float)
    return laser_position, laser_direction, laser_power