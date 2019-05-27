use check_gl;
use display::Image;
use failure;
use failure::Error;
use kernel_compilation;
use ocl;
use ocl::enums::ContextPropertyValue;
use settings::Settings;

// SSSRR
const DATA_WORDS: u32 = 5;

struct KernelImage {
    queue: ocl::Queue,
    width: u32,
    height: u32,
    scale: u32,
    scratch: Option<ocl::Buffer<f32>>,
    texture_cl: Option<ocl::Buffer<f32>>,
    texture_gl: Option<ocl::prm::cl_GLuint>,
}

impl KernelImage {
    fn new(queue: ocl::Queue, width: u32, height: u32) -> Self {
        Self {
            queue,
            width,
            height,
            scale: 1,
            scratch: None,
            texture_cl: None,
            texture_gl: None,
        }
    }

    fn size(&self) -> (u32, u32) {
        (self.width / self.scale, self.height / self.scale)
    }

    fn data(&mut self, is_ogl: bool) -> Result<(&ocl::Buffer<f32>, &ocl::Buffer<f32>), Error> {
        if self.texture_cl.is_none() {
            if is_ogl {
                //self.test();
                unsafe {
                    ::check_gl()?;
                    let mut buffer = 0;
                    let () = gl::CreateBuffers(1, &mut buffer);
                    ::check_gl()?;
                    gl::NamedBufferData(
                        buffer,
                        self.width as gl::types::GLsizeiptr
                            * self.height as gl::types::GLsizeiptr
                            * 4 // sizeof(float) * RGBA
                            * 4,
                        std::ptr::null(),
                        gl::DYNAMIC_DRAW, // TODO: fix this
                    );
                    self.texture_gl = Some(buffer);
                    let buffer_cl = ocl::Buffer::from_gl_buffer(&self.queue, None, buffer)?;
                    self.texture_cl = Some(buffer_cl);
                }
            } else {
                let new_data = ocl::Buffer::builder()
                    .context(&self.queue.context())
                    .len(self.width * self.height)
                    .build()?;
                self.texture_cl = Some(new_data);
            }
        }
        if self.scratch.is_none() {
            let new_data = ocl::Buffer::builder()
                .context(&self.queue.context())
                .len(self.width * self.height * DATA_WORDS)
                .build()?;
            self.scratch = Some(new_data);
        }
        Ok((
            self.texture_cl.as_ref().unwrap(),
            self.scratch.as_ref().unwrap(),
        ))
    }

    fn resize(&mut self, new_width: u32, new_height: u32) {
        if self.width != new_width || self.height != new_height {
            self.width = new_width;
            self.height = new_height;
            self.scratch = None;
            self.texture_cl = None;
            if let Some(id) = self.texture_gl {
                unsafe {
                    gl::DeleteBuffers(1, &id);
                }
            }
            self.texture_gl = None;
        }
    }

    fn rescale(&mut self, new_scale: u32) {
        self.scale = new_scale.max(1);
    }

    fn download(&mut self) -> Result<Image, Error> {
        let (width, height) = self.size();

        if let Some(gl) = self.texture_gl {
            Ok(Image::new(None, Some(gl), width, height))
        } else {
            let mut vec = vec![0.0; width as usize * height as usize * 4];

            // only read if data is present
            if let Some(ref buffer) = self.texture_cl {
                buffer.read(&mut vec).queue(&self.queue).enq()?;
            }

            Ok(Image::new(Some(vec), None, width, height))
        }
    }
}

pub struct Kernel {
    queue: ocl::Queue,
    kernel: Option<ocl::Kernel>,
    data: KernelImage,
    cpu_cfg: Vec<u8>,
    cfg: Option<ocl::Buffer<u8>>,
    old_settings: Settings,
    frame: u32,
    is_ogl: bool,
}

impl Kernel {
    pub fn create(
        width: u32,
        height: u32,
        is_ogl: bool,
        video: Option<&sdl2::VideoSubsystem>,
        settings: &mut Settings,
    ) -> Result<Self, Error> {
        // TODO: lazy_static context
        let context = Self::make_context(video)?;
        let device = context.devices()[0];
        let device_name = device.name()?;
        println!("Using device: {}", device_name);
        let queue = ocl::Queue::new(&context, device, None)?;
        let mut result = Kernel {
            queue: queue.clone(),
            kernel: None,
            data: KernelImage::new(queue, width, height),
            cpu_cfg: Vec::new(),
            cfg: None,
            old_settings: settings.clone(),
            frame: 0,
            is_ogl,
        };
        result.rebuild(settings)?;
        Ok(result)
    }

    pub fn rebuild(&mut self, settings: &mut Settings) -> Result<(), Error> {
        let new_kernel = kernel_compilation::rebuild(&self.queue, settings);
        match new_kernel {
            Ok(k) => {
                self.kernel = Some(k);
                self.frame = 0;
            }
            Err(err) => println!("Kernel compilation failed: {}", err),
        }
        Ok(())
    }

    fn make_context(video: Option<&sdl2::VideoSubsystem>) -> Result<ocl::Context, Error> {
        let mut last_err = None;
        let selected = ::std::env::var("CLAM5_DEVICE")
            .ok()
            .and_then(|x| x.parse::<u32>().ok());
        let mut i = 0;
        println!("Devices (pass env var CLAM5_DEVICE={{i}} to select)");
        for platform in ocl::Platform::list() {
            println!(
                "Platform: {} (version: {})",
                platform.name()?,
                platform.version()?,
            );
            for device in ocl::Device::list(platform, None)? {
                match selected {
                    Some(selected) if selected == i => {
                        return Self::build_ctx(platform, Some(device), video, false);
                    }
                    Some(_) => (),
                    None => println!("[{}]: {}", i, device.name()?),
                }
                i += 1;
            }
        }

        for platform in ocl::Platform::list() {
            match Self::build_ctx(platform, None, video, true) {
                Ok(ok) => return Ok(ok),
                Err(e) => last_err = Some(e),
            }
        }

        for platform in ocl::Platform::list() {
            match Self::build_ctx(platform, None, video, false) {
                Ok(ok) => return Ok(ok),
                Err(e) => last_err = Some(e),
            }
        }

        match last_err {
            Some(e) => Err(e.into()),
            None => Err(failure::err_msg("No OpenCL devices found")),
        }
    }

    fn build_ctx(
        platform: ocl::Platform,
        device: Option<ocl::Device>,
        video: Option<&sdl2::VideoSubsystem>,
        gpu: bool,
    ) -> Result<ocl::Context, Error> {
        let mut builder = ocl::Context::builder();
        builder.platform(platform);
        if let Some(device) = device {
            builder.devices(device);
        }
        if gpu && false {
            builder.devices(ocl::DeviceType::new().gpu());
        }
        if let Some(video) = video {
            unsafe {
                let gl_cx: extern "system" fn() -> *mut libc::c_void =
                    std::mem::transmute(video.gl_get_proc_address("wglGetCurrentContext"));
                let hdc: extern "system" fn() -> *mut libc::c_void =
                    std::mem::transmute(video.gl_get_proc_address("wglGetCurrentDC"));
                builder.property(ContextPropertyValue::GlContextKhr(gl_cx()));
                builder.property(ContextPropertyValue::WglHdcKhr(hdc()));
            }
            //builder.property(ContextPropertyValue::GlContextKhr());
        }
        return Ok(builder.build()?);
    }

    pub fn resize(&mut self, width: u32, height: u32) -> Result<(), Error> {
        self.data.resize(width, height);
        self.frame = 0;
        Ok(())
    }

    fn update(&mut self, settings: &Settings) -> Result<(), Error> {
        let new_cfg = settings.serialize();
        if new_cfg != self.cpu_cfg {
            if new_cfg.len() != self.cpu_cfg.len() {
                if new_cfg.is_empty() {
                    self.cfg = None;
                } else {
                    self.cfg = Some(
                        ocl::Buffer::builder()
                            .context(&self.queue.context())
                            .len(new_cfg.len())
                            .build()?,
                    );
                }
            }
            self.cpu_cfg = new_cfg;
            let to_write = &self.cpu_cfg as &[_];
            if let Some(ref cfg) = self.cfg {
                cfg.write(to_write).queue(&self.queue).enq()?;
            }
            self.frame = 0;
        }

        if *settings != self.old_settings {
            self.old_settings = settings.clone();
            self.frame = 0;
        }

        self.data
            .rescale(settings.find("render_scale").unwrap_u32());

        Ok(())
    }

    fn set_args(&mut self) -> Result<(), Error> {
        if let Some(ref kernel) = self.kernel {
            let (width, height) = self.data.size();
            let (texture, scratch) = self.data.data(self.is_ogl)?;
            kernel.set_arg(0, texture)?;
            kernel.set_arg(1, scratch)?;
            kernel.set_arg(2, self.cfg.as_ref())?;
            kernel.set_arg(3, width as u32)?;
            kernel.set_arg(4, height as u32)?;
            kernel.set_arg(5, self.frame as u32)?;
        }
        Ok(())
    }

    fn launch(&mut self) -> Result<(), Error> {
        if let Some(ref kernel) = self.kernel {
            let (width, height) = self.data.size();
            let total_size = width * height;

            if self.is_ogl {
                if let Some(ref buf) = self.data.texture_cl {
                    unsafe { gl::Finish() };
                    check_gl()?;
                    buf.cmd().gl_acquire().enq()?;
                }
            }
            let to_launch = kernel.cmd().queue(&self.queue).global_work_size(total_size);
            // enq() is unsafe, even though the Rust code is safe (unsafe due to untrusted GPU code)
            unsafe { to_launch.enq() }?;

            if self.is_ogl {
                if let Some(ref buf) = self.data.texture_cl {
                    buf.cmd().gl_release().enq()?;
                    self.queue.finish()?;
                    unsafe { gl::Finish() };
                }
            }

            self.frame += 1;
        }

        Ok(())
    }

    pub fn run(&mut self, settings: &mut Settings, force_rebuild: bool) -> Result<(), Error> {
        if settings.check_rebuild() || force_rebuild {
            self.rebuild(settings)?;
            println!("Rebuilding");
        }
        self.update(settings)?;
        self.set_args()?;
        self.launch()?;
        Ok(())
    }

    pub fn download(&mut self) -> Result<Image, Error> {
        self.data.download()
    }

    pub fn sync_renderer(&mut self) -> ocl::Result<()> {
        self.queue.finish()
    }
}
