﻿using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Xml.Linq;
using Cloo;
using JetBrains.Annotations;
using OpenTK;

namespace Clam
{
    struct RenderPackage : IDisposable
    {
        private readonly RenderKernel _kernel;
        private readonly IParameterSet _parameters;
        private static volatile int _kernelInUse;

        public RenderPackage([NotNull] RenderKernel kernel, [NotNull] IParameterSet parameters)
        {
            _kernel = kernel;
            _parameters = parameters;
        }

        public RenderKernel Kernel
        {
            get { return _kernel; }
        }

        public IParameterSet Parameters
        {
            get { return _parameters; }
        }

        public static bool KernelInUse
        {
            get { return _kernelInUse != 0; }
        }

        private static readonly Dictionary<string, Func<RenderWindow, IParameterSet>> ControlBindings = new Dictionary<string, Func<RenderWindow, IParameterSet>>
        {
            {"Raytracer", w => new KeyboardRaytracerControl(w)},
            {"RaytracerExtended", w => new KeyboardRaytracerControlExtended(w)},
            {"2D", w => new Keyboard2DControl(w)},
        };

        public static RenderPackage? LoadFromXml(RenderWindow window, string xmlFilename)
        {
            var xml = XDocument.Load(xmlFilename).Root;
            if (xml == null)
                throw new Exception("Invalid XML file " + xmlFilename + ": no root element");
            var controls = xml.Element("Controls");
            if (controls == null)
                throw new Exception("Invalid XML file " + xmlFilename + ": no Controls element");
            if (!ControlBindings.ContainsKey(controls.Value))
                throw new Exception("Invalid XML file " + xmlFilename + ": Controls value did not exist, possible values are: " + string.Join(", ", ControlBindings.Keys));
            var parameters = ControlBindings[controls.Value](window);
            var files = xml.Element("Files");
            if (files == null)
                throw new Exception("Invalid XML file " + xmlFilename + ": no Files element");
            var sourceStrings = files.Elements("File").Select(e => File.ReadAllText(e.Value)).ToArray();
            var kernel = RenderKernel.Create(window.ComputeContext, sourceStrings);
            if (kernel == null)
                return null;
            return new RenderPackage(kernel, parameters);
        }

        private const double ScreenshotAspectRatio = 16.0 / 9.0;
        public Bitmap Screenshot(int screenshotHeight, int slowRenderPower)
        {
            _kernelInUse++;
            RenderWindow.DisplayInformation("Rendering screenshot");
            var screenshotWidth = (int)(screenshotHeight * ScreenshotAspectRatio);
            var computeBuffer = new ComputeBuffer<Vector4>(_kernel.ComputeContext, ComputeMemoryFlags.ReadWrite, screenshotWidth * screenshotHeight);
            var queue = new ComputeCommandQueue(_kernel.ComputeContext, _kernel.ComputeContext.Devices[0], ComputeCommandQueueFlags.None);

            const int numFrames = 150;
            var frameDependantControls = _parameters as IFrameDependantControl;
            for (var frame = 0; frame < (frameDependantControls == null ? 1 : numFrames); frame++)
            {
                if (frameDependantControls != null)
                    frameDependantControls.Frame = frame;
                for (var y = 0; y < slowRenderPower; y++)
                {
                    for (var x = 0; x < slowRenderPower; x++)
                    {
                        RenderWindow.DisplayInformation(string.Format("Screenshot {0}% done",
                            100 * (x + y * slowRenderPower + frame * slowRenderPower * slowRenderPower) /
                            (slowRenderPower * slowRenderPower * (frameDependantControls == null ? 1 : numFrames))));
                        _kernel.Render(computeBuffer, queue, _parameters, new Size(screenshotWidth, screenshotHeight), slowRenderPower, new Size(x, y));
                    }
                }
            }

            var pixels = new Vector4[screenshotWidth * screenshotHeight];
            queue.ReadFromBuffer(computeBuffer, ref pixels, true, null);
            queue.Finish();

            computeBuffer.Dispose();
            queue.Dispose();

            RenderWindow.DisplayInformation("Saving screenshot");
            var bmp = new Bitmap(screenshotWidth, screenshotHeight);
            var destBuffer = new int[screenshotWidth * screenshotHeight];
            int nancount = 0;
            for (var y = 0; y < screenshotHeight; y++)
            {
                for (var x = 0; x < screenshotWidth; x++)
                {
                    var pixel = pixels[x + y * screenshotWidth];
                    if (float.IsNaN(pixel.X) || float.IsNaN(pixel.Y) || float.IsNaN(pixel.Z))
                    {
                        nancount++;
                        continue;
                    }
                    destBuffer[y * screenshotWidth + x] = (byte)(pixel.X * 255) << 16 | (byte)(pixel.Y * 255) << 8 | (byte)(pixel.Z * 255);
                }
            }
            if (nancount != 0)
                Console.WriteLine("Warning! Caught {0} NAN pixels while taking screenshot!", nancount);
            var bmpData = bmp.LockBits(new Rectangle(0, 0, screenshotWidth, screenshotHeight), ImageLockMode.ReadWrite, PixelFormat.Format32bppRgb);
            Marshal.Copy(destBuffer, 0, bmpData.Scan0, destBuffer.Length);
            bmp.UnlockBits(bmpData);

            RenderWindow.DisplayInformation("Done rendering screenshot");
            _kernelInUse--;
            return bmp;
        }

        public void Dispose()
        {
            if (_kernel != null)
                _kernel.Dispose();
        }
    }
}