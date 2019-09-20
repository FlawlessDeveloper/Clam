use crate::check_gl;
use crate::gl_help::{set_arg_u32, CpuTexture, Texture, TextureType};
use crate::kernel_compilation;
use crate::settings::Settings;
use failure;
use failure::Error;
use gl::types::*;

struct KernelImage<T: TextureType> {
    width: usize,
    height: usize,
    scale: usize,
    scratch: Option<Texture<[f32; 4]>>,
    output: Option<Texture<T>>,
}

impl<T: TextureType> KernelImage<T> {
    fn new(width: usize, height: usize) -> Self {
        Self {
            width,
            height,
            scale: 1,
            scratch: None,
            output: None,
        }
    }

    fn size(&self) -> (usize, usize) {
        (self.width / self.scale, self.height / self.scale)
    }

    fn data(&mut self) -> Result<(&Texture<T>, &Texture<[f32; 4]>), Error> {
        let (width, height) = self.size();
        if self.output.is_none() {
            self.output = Some(Texture::new(width, height)?);
        }
        if self.scratch.is_none() {
            self.scratch = Some(Texture::new(width, height)?);
        }
        Ok((
            self.output.as_ref().expect("Didn't assign output?"),
            self.scratch.as_ref().expect("Didn't assign scratch?"),
        ))
    }

    fn resize(
        &mut self,
        new_width: usize,
        new_height: usize,
        new_scale: usize,
    ) -> Result<(), Error> {
        let old_size = self.size();
        self.width = new_width;
        self.height = new_height;
        self.scale = new_scale.max(1);
        if old_size != self.size() {
            self.scratch = None;
            self.output = None;
        }
        Ok(())
    }

    fn download(&mut self) -> Result<CpuTexture<T>, Error> {
        self.output
            .as_mut()
            .ok_or_else(|| failure::err_msg("Cannot download image that hasn't been created yet"))
            .and_then(|img| img.download())
    }
}

pub struct FractalKernel<T: TextureType> {
    kernel: Option<GLuint>,
    data: KernelImage<T>,
    //cpu_cfg: Vec<u8>,
    //cfg: Option<Buffer<u8>>,
    old_settings: Settings,
    frame: u32,
}

impl<T: TextureType> FractalKernel<T> {
    pub fn create(width: usize, height: usize, settings: &mut Settings) -> Result<Self, Error> {
        kernel_compilation::refresh_settings(settings)?;
        let result = Self {
            kernel: None,
            data: KernelImage::new(width, height),
            old_settings: settings.clone(),
            frame: 0,
        };
        Ok(result)
    }

    pub fn rebuild(&mut self, settings: &mut Settings, force_rebuild: bool) -> Result<(), Error> {
        if settings.check_rebuild() || self.kernel.is_none() || force_rebuild {
            println!("Rebuilding");
            let new_kernel = kernel_compilation::rebuild(settings);
            match new_kernel {
                Ok(k) => {
                    self.kernel = Some(k);
                    self.frame = 0;
                }
                //Err(err) => println!("Kernel compilation failed: {}", err),
                Err(err) => return Err(err), // TODO
            }
        }
        Ok(())
    }

    pub fn resize(&mut self, width: usize, height: usize) -> Result<(), Error> {
        self.data.resize(width, height, self.data.scale)?;
        self.frame = 0;
        Ok(())
    }

    fn update(&mut self, settings: &Settings) -> Result<(), Error> {
        if let Some(kernel) = self.kernel {
            settings.set_uniforms(kernel)?;
        }

        if *settings != self.old_settings {
            self.old_settings = settings.clone();
            self.frame = 0;
        }

        self.data.resize(
            self.data.width,
            self.data.height,
            settings.find("render_scale").unwrap_u32() as usize,
        )?;

        Ok(())
    }

    fn set_args(&mut self) -> Result<(), Error> {
        let (width, height) = self.data.size();
        if let Some(kernel) = self.kernel {
            set_arg_u32(kernel, "width", width as u32)?;
            set_arg_u32(kernel, "height", height as u32)?;
            set_arg_u32(kernel, "frame", self.frame)?;
        }
        Ok(())
    }

    fn launch(&mut self) -> Result<(), Error> {
        if let Some(kernel) = self.kernel {
            let (width, height) = self.data.size();
            let (texture, scratch) = self.data.data()?;
            let total_size = width * height;
            unsafe {
                gl::UseProgram(kernel);
                check_gl()?;
                texture.bind(0)?;
                scratch.bind(1)?;
                check_gl()?;
                gl::DispatchCompute(total_size as u32, 1, 1);
                check_gl()?;
                gl::UseProgram(0);
                check_gl()?;
            }
            self.frame += 1;
        }
        Ok(())
    }

    pub fn run(&mut self, settings: &mut Settings, force_rebuild: bool) -> Result<(), Error> {
        self.rebuild(settings, force_rebuild)?;
        self.update(settings)?;
        self.set_args()?;
        self.launch()?;
        Ok(())
    }

    pub fn texture(&mut self) -> Result<&Texture<T>, Error> {
        Ok(self.data.data()?.0)
    }

    pub fn download(&mut self) -> Result<CpuTexture<T>, Error> {
        self.data.download()
    }

    pub fn sync_renderer(&mut self) -> Result<(), Error> {
        unsafe {
            gl::Finish();
            check_gl()
        }
    }
}
