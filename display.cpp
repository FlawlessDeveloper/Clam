#include "display.h"
#include "option.h"

struct SdlInitClass
{
    SdlInitClass()
    {
        if (SDL_Init(SDL_INIT_TIMER | SDL_INIT_VIDEO))
        {
            throw std::runtime_error(SDL_GetError());
        }
        if (TTF_Init())
        {
            throw std::runtime_error(TTF_GetError());
        }
    }

    ~SdlInitClass()
    {
        TTF_Quit();
        SDL_Quit();
    }
} sdlInitInstance;

DisplayWindow::DisplayWindow(int x, int y, int width, int height)
{
    isUserInput = IsUserInput();
    // TODO: SDL_WINDOW_FULLSCREEN
    Uint32 flags;
    flags = SDL_WINDOW_RESIZABLE;
    window = SDL_CreateWindow("Clam3", x, y, width, height, flags);
    // TODO: $CLAM3_FONT
    font = TTF_OpenFont("/usr/share/fonts/TTF/Inconsolata-Regular.ttf", 14);
    if (!font)
    {
        throw std::runtime_error("Could not open font /usr/share/fonts/TTF/Inconsolata-Regular.ttf");
    }
    lastTicks = SDL_GetTicks();
}

DisplayWindow::~DisplayWindow()
{
    if (font)
    {
        TTF_CloseFont(font);
    }
    if (window)
    {
        SDL_DestroyWindow(window);
    }
}

bool DisplayWindow::UserInput(Kernel *kernel)
{
    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        if (isUserInput)
        {
            kernel->UserInput(event);
        }
        if (event.type == SDL_QUIT)
        {
            return false;
        }
    }
    Uint32 newTicks = SDL_GetTicks();
    double time = (newTicks - lastTicks) / 1000.0;
    lastTicks = newTicks;
    if (isUserInput)
    {
        kernel->Integrate(time);
    }
    return true;
}
