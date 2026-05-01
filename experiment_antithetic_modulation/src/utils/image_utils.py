import sys
sys.path.append("../")
import numpy as np
import cv2 as cv
from PIL import Image
import glob
import matplotlib.pyplot as plt
import os
import cv2
from utils.math_utils import *

def load_exr_image(path, invert=False):
    image = cv.imread(path, -1).astype(np.float32)
    image = cv.cvtColor(image, cv.COLOR_RGB2BGRA)
    if invert:
        image = cv.flip(image, 0)
    return image


def convert_image_to_uint(image):
    x = np.copy(image)
    x *= 255
    x = np.clip(x, 0, 255)
    x = x.astype('uint8')
    return x


def save_image(image, file_path):
    x = convert_image_to_uint(image)
    new_im = Image.fromarray(x)
    dirname = os.path.dirname(file_path)
    if not os.path.exists(dirname):
        os.makedirs(dirname)
    if file_path.endswith(".png"):
        new_im.save("%s" % file_path)
    else:
        new_im.save("%s.png" % file_path)


def save_image_numpy(image, file_path):
    dirname = os.path.dirname(file_path)
    if not os.path.exists(dirname):
        os.makedirs(dirname)
    if file_path.endswith(".npy"):
        np.save("%s" % file_path, image)
    else:
        np.save("%s.npy" % file_path, image)


def load_reference_image(parent_folder, name):
    target_name = "%s/%s_*.png" % (parent_folder, name)
    files = glob.glob(target_name)
    load_file = files[0]
    return load_image(load_file)


def load_image(path):
    image = Image.open(path)
    image = np.asarray(image, dtype=np.float32)
    image = image[:, :, 0:3]
    image /= 255.0
    return image


def export_video(output_path_image, N, output_path,file_name="merged"):
    images = []
    for i in range(N):
        image = cv2.imread(os.path.join(output_path_image, "%d.png" % i))
        images.append(image)

    images = np.asarray(images)
    export_video_from_images(images, os.path.join(output_path, "video"), file_name)

def export_video_from_images(images, outputdir, output_file_name, fps=24):
    if not os.path.exists(outputdir):
        os.makedirs(outputdir)

    image_0 = images[0]
    height = image_0.shape[0]
    width = image_0.shape[1]
    size = (width, height)
    out  = cv2.VideoWriter(os.path.join(outputdir, "%s.mp4" % output_file_name),  cv2.VideoWriter_fourcc(*'mp4v'), fps, size)

    for image in images:
        out.write(image)
    
    out.release()

def save_histogram(histogram, output_folder, export_video=False, export_image=True):
    bin_size = histogram.shape[0]

    if export_image:
        for i in range(bin_size):
            image = histogram[i]
            ldr_image = LinearToSrgb(ToneMap(image, 1.5))
            save_image(ldr_image, "%s/histogram/bin_%d.png"%(output_folder, i))
    
    np.save("%s/histogram.npy"%(output_folder), histogram[..., 0])

    if export_video:
        images = []
        for i in range(bin_size):
            image = cv2.imread("%s/histogram/bin_%d.png"%(output_folder, i))
            images.append(image)
        images = np.asarray(images)
        export_video_from_images(images, "%s/video"%(output_folder), "histogram")