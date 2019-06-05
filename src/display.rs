use crate::check_gl;
use crate::fps_counter::FpsCounter;
use crate::gl_register_debug;
use crate::input::Input;
use crate::interactive::SyncInteractiveKernel;
use crate::kernel;
use crate::settings::Settings;
use failure::err_msg;
use failure::Error;
use gl::types::*;
use ocl::OclPrm;
use sdl2::event::Event;
use sdl2::event::WindowEvent;
use sdl2::init;
use sdl2::pixels::Color;
use sdl2::pixels::PixelFormat;
use sdl2::pixels::PixelFormatEnum;
use sdl2::ttf;
use sdl2::video::Window;
use std::path::Path;

pub struct ImageData<T: OclPrm> {
    pub data_cpu: Option<Vec<T>>,
    pub data_gl: Option<GLuint>,
    pub width: u32,
    pub height: u32,
}

impl<T: OclPrm> ImageData<T> {
    pub fn new(data_cpu: Option<Vec<T>>, data_gl: Option<GLuint>, width: u32, height: u32) -> Self {
        Self {
            data_cpu,
            data_gl,
            width,
            height,
        }
    }
}

unsafe fn buffer_blit(
    buffer: GLuint,
    framebuffer: &mut GLuint,
    image_width: i32,
    image_height: i32,
    screen_width: i32,
    screen_height: i32,
) -> Result<(), Error> {
    if *framebuffer == 0 {
        gl::CreateFramebuffers(1, framebuffer);
        check_gl()?;
        gl::NamedFramebufferTexture(*framebuffer, gl::COLOR_ATTACHMENT0, buffer, 0);
        check_gl()?;
    }

    let dest_buf = 0;
    gl::BlitNamedFramebuffer(
        *framebuffer,
        dest_buf,
        0,
        0,
        image_width,
        image_height,
        0,
        0,
        screen_width,
        screen_height,
        gl::COLOR_BUFFER_BIT,
        gl::NEAREST,
    );
    check_gl()?;
    Ok(())
}

fn find_font() -> Result<&'static Path, Error> {
    let locations: [&'static Path; 6] = [
        "/usr/share/fonts/TTF/FiraMono-Regular.ttf".as_ref(),
        "/usr/share/fonts/TTF/FiraSans-Regular.ttf".as_ref(),
        "C:\\Windows\\Fonts\\arial.ttf".as_ref(),
        "/usr/share/fonts/TTF/DejaVuSans.ttf".as_ref(),
        "/usr/share/fonts/TTF/LiberationSans-Regular.ttf".as_ref(),
        "/Library/Fonts/Andale Mono.ttf".as_ref(),
    ];
    for &location in &locations {
        if location.exists() {
            return Ok(location);
        }
    }
    Err(err_msg("No font found"))
}

fn render_text_one(
    font: &ttf::Font,
    text: &str,
    color: Color,
    window_height: i32,
    offset_x: i32,
    offset_y: i32,
) -> Result<(), Error> {
    let spacing = font.recommended_line_spacing();
    let mut current_y = 10;
    let mut current_column_x = 10;
    let mut next_column_x = 0;
    for line in text.lines() {
        let format = unsafe {
            PixelFormat::from_ll(sdl2::sys::SDL_AllocFormat(PixelFormatEnum::RGBA8888 as u32))
        };
        let rendered = font
            .render(line)
            .solid(color)?
            .convert(&format)
            .expect("Could not convert text image format");
        unsafe {
            sdl2::sys::SDL_FreeFormat(format.raw());
        }
        let width = rendered.width() as i32;
        let height = rendered.height() as i32;
        if (current_y + spacing) >= (window_height as i32) {
            current_column_x = next_column_x;
            current_y = 10;
        }
        next_column_x = next_column_x.max(current_column_x + width);

        unsafe {
            let mut texture = 0;
            gl::CreateTextures(gl::TEXTURE_2D, 1, &mut texture);
            check_gl()?;
            gl::TextureStorage2D(texture, 1, gl::RGBA8, width, height);
            check_gl()?;
            rendered.with_lock(|data| {
                gl::TextureSubImage2D(
                    texture,
                    0,
                    0,
                    0,
                    width,
                    height,
                    gl::RGBA,
                    gl::UNSIGNED_INT_8_8_8_8,
                    data.as_ptr() as _,
                )
            });
            check_gl()?;

            let mut framebuffer = 0;
            gl::CreateFramebuffers(1, &mut framebuffer);
            check_gl()?;
            gl::NamedFramebufferTexture(framebuffer, gl::COLOR_ATTACHMENT0, texture, 0);
            check_gl()?;

            let dest_buf = 0;
            gl::BlitNamedFramebuffer(
                framebuffer,
                dest_buf,
                0,
                0,
                width,
                height,
                current_column_x + offset_x,
                window_height - (current_y + offset_y + 1),
                current_column_x + offset_x + width,
                window_height - (current_y + offset_y + height),
                gl::COLOR_BUFFER_BIT,
                gl::NEAREST,
            );
            check_gl()?;

            gl::DeleteFramebuffers(1, &framebuffer);
            check_gl()?;
            gl::DeleteTextures(1, &texture);
            check_gl()?;
        }

        // rendered
        //     .blit(
        //         None,
        //         window,
        //         Rect::new(
        //             current_column_x + offset_x,
        //             current_y + offset_y,
        //             width,
        //             height,
        //         ),
        //     )
        //     .expect("Could not blit SDL2 font");

        current_y += spacing;
    }
    Ok(())
}

fn render_text(
    window: &Window,
    input: &Input,
    settings: &Settings,
    font: &ttf::Font,
    fps: f64,
) -> Result<(), Error> {
    let (_, window_height) = window.drawable_size();
    let fps_text = format!("{:.2} render fps", fps);
    let text = format!("{}\n{}", fps_text, settings.status(input));
    render_text_one(font, &text, Color::RGB(0, 0, 0), window_height as i32, 1, 1)?;
    render_text_one(
        font,
        &text,
        Color::RGB(255, 192, 192),
        window_height as i32,
        0,
        0,
    )?;
    Ok(())
}

pub fn gl_display(mut screen_width: u32, mut screen_height: u32) -> Result<(), Error> {
    let is_gl = true;
    let sdl = init().expect("SDL failed to init");
    let video = sdl.video().expect("SDL does not have video");
    let mut event_pump = sdl.event_pump().expect("SDL does not have event pump");

    let ttf = ttf::init()?;
    let font = ttf.load_font(find_font()?, 20).expect("Cannot open font");

    video.gl_attr().set_context_flags().debug().set();

    let window = video
        .window("clam5", screen_width, screen_height)
        .opengl()
        .build()?;
    let _gl_context = window
        .gl_create_context()
        .expect("Failed to create OpenGL context");

    gl::load_with(|s| video.gl_get_proc_address(s) as *const _);

    if !gl::GetError::is_loaded() {
        return Err(failure::err_msg("glGetError not loaded"));
    }

    unsafe { gl::Enable(gl::DEBUG_OUTPUT_SYNCHRONOUS) };
    check_gl()?;

    gl_register_debug()?;

    kernel::init_gl_funcs(&video);

    let mut interactive_kernel =
        SyncInteractiveKernel::<f32>::create(screen_width, screen_height, is_gl)?;

    let mut fps = FpsCounter::new(1.0);

    let mut framebuffer = 0;
    loop {
        for event in event_pump.poll_iter() {
            match event {
                Event::Window {
                    win_event: WindowEvent::Resized(width, height),
                    ..
                } if width > 0 && height > 0 => {
                    screen_width = width as u32;
                    screen_height = height as u32;
                    interactive_kernel.resize(width as u32, height as u32)?;
                }
                Event::KeyDown {
                    scancode: Some(scancode),
                    ..
                } => {
                    interactive_kernel.key_down(scancode);
                }
                Event::KeyUp {
                    scancode: Some(scancode),
                    ..
                } => {
                    interactive_kernel.key_up(scancode);
                }
                Event::Quit { .. } => return Ok(()),
                _ => (),
            }
        }

        interactive_kernel.launch()?;
        let img = interactive_kernel.download()?;

        unsafe {
            buffer_blit(
                img.data_gl.expect("gl_display needs OGL texture"),
                &mut framebuffer,
                img.width as i32,
                img.height as i32,
                screen_width as i32,
                screen_height as i32,
            )
        }?;

        if false {
            render_text(
                &window,
                &interactive_kernel.input,
                &interactive_kernel.settings,
                &font,
                fps.value(),
            )?;
        } else {
            interactive_kernel.print_status(&fps);
        }

        window.gl_swap_window();

        fps.tick();
    }
}

fn matmul(mat: &[[f32; 4]; 3], vec: &[f32; 3]) -> [f32; 3] {
    [
        mat[0][0] * vec[0] + mat[0][1] * vec[1] + mat[0][2] * vec[2] + mat[0][3],
        mat[1][0] * vec[0] + mat[1][1] * vec[1] + mat[1][2] * vec[2] + mat[1][3],
        mat[2][0] * vec[0] + mat[2][1] * vec[1] + mat[2][2] * vec[2] + mat[2][3],
    ]
}

fn matmul_dir(mat: &[[f32; 4]; 3], vec: &[f32; 3]) -> [f32; 3] {
    [
        mat[0][0] * vec[0] + mat[0][1] * vec[1] + mat[0][2] * vec[2],
        mat[1][0] * vec[0] + mat[1][1] * vec[1] + mat[1][2] * vec[2],
        mat[2][0] * vec[0] + mat[2][1] * vec[1] + mat[2][2] * vec[2],
    ]
}

unsafe fn hands_eye(
    system: &openvr::System,
    eye: openvr::Eye,
    head: &openvr::TrackedDevicePose,
    settings: &mut Settings,
) {
    let eye_to_head = system.eye_to_head_transform(eye);
    let head_to_absolute = head.device_to_absolute_tracking();

    let pos = matmul(&head_to_absolute, &matmul(&eye_to_head, &[0.0, 0.0, 0.0]));
    // let right = matmul_dir(
    //     &head_to_absolute,
    //     &matmul_dir(&eye_to_head, &[1.0, 0.0, 0.0]),
    // );
    let up = matmul_dir(
        &head_to_absolute,
        &matmul_dir(&eye_to_head, &[0.0, 1.0, 0.0]),
    );
    let forwards = matmul_dir(
        &head_to_absolute,
        &matmul_dir(&eye_to_head, &[0.0, 0.0, -1.0]),
    );
    *settings.find_mut("pos_x").unwrap_f32_mut() = pos[0] * 4.0;
    *settings.find_mut("pos_y").unwrap_f32_mut() = pos[1] * 4.0 - 4.0;
    *settings.find_mut("pos_z").unwrap_f32_mut() = pos[2] * 4.0;
    *settings.find_mut("look_x").unwrap_f32_mut() = forwards[0];
    *settings.find_mut("look_y").unwrap_f32_mut() = forwards[1];
    *settings.find_mut("look_z").unwrap_f32_mut() = forwards[2];
    *settings.find_mut("up_x").unwrap_f32_mut() = up[0];
    *settings.find_mut("up_y").unwrap_f32_mut() = up[1];
    *settings.find_mut("up_z").unwrap_f32_mut() = up[2];
}

unsafe fn hands(
    system: &openvr::System,
    compositor: &openvr::Compositor,
    settings_left: &mut Settings,
    settings_right: &mut Settings,
) -> Result<(), Error> {
    let _ =
        system.tracked_device_index_for_controller_role(openvr::TrackedControllerRole::LeftHand);
    let _ =
        system.tracked_device_index_for_controller_role(openvr::TrackedControllerRole::RightHand);
    let wait_poses: openvr::compositor::WaitPoses = compositor.wait_get_poses()?;

    // render = upcoming frame
    // game = 2 frames from now
    let head: &openvr::TrackedDevicePose = &wait_poses.render[0];

    hands_eye(system, openvr::Eye::Left, head, settings_left);
    hands_eye(system, openvr::Eye::Right, head, settings_right);
    Ok(())
}

unsafe fn render_eye(
    compositor: &openvr::Compositor,
    eye: openvr::Eye,
    texture: GLuint,
) -> Result<(), Error> {
    check_gl()?;

    let ovr_tex = openvr::compositor::Texture {
        handle: openvr::compositor::texture::Handle::OpenGLTexture(texture as usize),
        color_space: openvr::compositor::texture::ColorSpace::Gamma,
    };
    compositor
        .submit(eye, &ovr_tex, None, None)
        .expect("Eye failed to submit");
    check_gl()?;
    Ok(())
}

pub fn vr_display() -> Result<(), Error> {
    let is_gl = true;
    let sdl = init().expect("SDL failed to init");
    let video = sdl.video().expect("SDL does not have video");
    let mut event_pump = sdl.event_pump().expect("SDL does not have event pump");

    video.gl_attr().set_context_flags().debug().set();

    let window = video.window("clam5", 500, 500).opengl().build()?;
    let _gl_context = window
        .gl_create_context()
        .expect("Failed to create OpenGL context");

    gl::load_with(|s| video.gl_get_proc_address(s) as *const _);

    if !gl::GetError::is_loaded() {
        return Err(failure::err_msg("glGetError not loaded"));
    }

    unsafe { gl::Enable(gl::DEBUG_OUTPUT_SYNCHRONOUS) };
    check_gl()?;

    gl_register_debug()?;

    kernel::init_gl_funcs(&video);

    let ovr = unsafe { openvr::init(openvr::ApplicationType::Scene)? };
    let system = ovr.system()?;
    let compositor = ovr.compositor()?;
    let (width, height) = system.recommended_render_target_size();
    check_gl()?;

    let mut interactive_kernel_left = SyncInteractiveKernel::<u8>::create(width, height, is_gl)?;
    let mut interactive_kernel_right = SyncInteractiveKernel::<u8>::create(width, height, is_gl)?;
    interactive_kernel_left
        .settings
        .find_mut("VR")
        .set_const(true);
    interactive_kernel_right
        .settings
        .find_mut("VR")
        .set_const(true);
    *interactive_kernel_left
        .settings
        .find_mut("dof_amount")
        .unwrap_f32_mut() = 0.0;
    *interactive_kernel_right
        .settings
        .find_mut("dof_amount")
        .unwrap_f32_mut() = 0.0;

    let proj_left = system.projection_raw(openvr::Eye::Left);
    *interactive_kernel_left
        .settings
        .find_mut("fov_left")
        .unwrap_f32_mut() = proj_left.left;
    *interactive_kernel_left
        .settings
        .find_mut("fov_right")
        .unwrap_f32_mut() = proj_left.right;
    *interactive_kernel_left
        .settings
        .find_mut("fov_top")
        .unwrap_f32_mut() = proj_left.top;
    *interactive_kernel_left
        .settings
        .find_mut("fov_bottom")
        .unwrap_f32_mut() = proj_left.bottom;

    let proj_right = system.projection_raw(openvr::Eye::Right);
    *interactive_kernel_right
        .settings
        .find_mut("fov_left")
        .unwrap_f32_mut() = proj_right.left;
    *interactive_kernel_right
        .settings
        .find_mut("fov_right")
        .unwrap_f32_mut() = proj_right.right;
    *interactive_kernel_right
        .settings
        .find_mut("fov_top")
        .unwrap_f32_mut() = proj_right.top;
    *interactive_kernel_right
        .settings
        .find_mut("fov_bottom")
        .unwrap_f32_mut() = proj_right.bottom;

    let mut fps = FpsCounter::new(1.0);

    loop {
        for event in event_pump.poll_iter() {
            if let Event::Quit { .. } = event {
                return Ok(());
            }
        }

        unsafe {
            hands(
                &system,
                &compositor,
                &mut interactive_kernel_left.settings,
                &mut interactive_kernel_right.settings,
            )?;
        }

        interactive_kernel_left.launch()?;
        interactive_kernel_right.launch()?;
        let left_img = interactive_kernel_left
            .download()?
            .data_gl
            .expect("vr_display needs OGL textures");
        let right_img = interactive_kernel_right
            .download()?
            .data_gl
            .expect("vr_display needs OGL textures");

        unsafe {
            render_eye(&compositor, openvr::Eye::Left, left_img)?;
            render_eye(&compositor, openvr::Eye::Right, right_img)?;
        }

        window.gl_swap_window();

        fps.tick();
        println!("{:.2}fps", fps.value());
    }
}
